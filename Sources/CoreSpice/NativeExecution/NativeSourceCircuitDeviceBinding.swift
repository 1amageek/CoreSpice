import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceOSDIContracts
import CoreSpiceOSDI
import OSDIContracts
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import Synchronization

/// Reexecutes captured source scalars and retains a bounded ledger of actual fresh preparations.
public final class NativeSourceCircuitDeviceBinding: SourceResolvingCircuitDeviceBinding {
    private struct CancellationAccounting: SPICESourceResourceAccounting {
        let original: any SPICESourceResourceAccounting
        let cancellation: CancellationToken
        func checkCancellation() throws {
            try NativeCircuitExecution.check(cancellation)
            try original.checkCancellation()
        }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation(); try original.charge(kind, units: units)
        }
        func chargeHashedBytes(_ byteCount: UInt64) throws {
            try checkCancellation(); try original.chargeHashedBytes(byteCount)
        }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation(); return try original.reserveStorage(kind: kind, byteCount: byteCount)
        }
    }
    private struct SourceFinalizer: AnalysisCompletionFinalizing {
        let prior: any AnalysisCompletionFinalizing
        let release: @Sendable () -> Void
        func finalizeCompletion() throws { try prior.finalizeCompletion(); release() }
    }
    private struct State {
        var records: [SPICENativeSourceReexecutionRecord]
        var activePreparation: NativeCircuitPreparationRecord? = nil
        var inventory: PreparedSPICESimulation? = nil
        var inventoryLoading = false
        var started = 0
        var active = 0
        var finished = false
    }
    private let state: Mutex<State>
    private let baselinePreparation: NativeCircuitPreparationRecord?
    private let input: PreparedSPICESimulation
    private let limits: SPICENativeExecutionLimits
    private let maximumReexecutions: Int
    private let cancellation: CancellationToken
    private let reservation: SPICESourceStorageReservation

    internal static func sensitivityCapacity(_ input: PreparedSPICESimulation) throws -> Int {
        var count = input.lowered.evaluationProvenance.sourceScalars.count
        for resolved in input.request.osdiInstances.values {
            let (models, modelOverflow) = count.addingReportingOverflow(resolved.binding.modelParameters.count)
            guard !modelOverflow else { throw SPICENativePreparationError.capacityExceeded }; count = models
            let (instances, instanceOverflow) = count.addingReportingOverflow(resolved.instanceParameters.count)
            guard !instanceOverflow else { throw SPICENativePreparationError.capacityExceeded }; count = instances
        }
        return max(1, count)
    }

    public init(input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits,
                maximumReexecutions: Int, cancellation: CancellationToken,
                baselinePreparation: NativeCircuitPreparationRecord? = nil) throws {
        self.baselinePreparation = baselinePreparation
        guard maximumReexecutions > 0 else { throw SPICENativePreparationError.invalidLimits }
        let bytes = try NativeCircuitExecution.capacityProduct(UInt64(maximumReexecutions),
            UInt64(2 * (MemoryLayout<SPICENativeSourceReexecutionRecord>.stride + MemoryLayout<SPICENativeSourceReexecutionCompletion>.stride)))
        guard bytes <= limits.maximumAllocationBytes else { throw SPICENativePreparationError.capacityExceeded }
        let reservation = try input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        var records: [SPICENativeSourceReexecutionRecord] = []; records.reserveCapacity(maximumReexecutions)
        self.input = input; self.limits = limits; self.maximumReexecutions = maximumReexecutions
        self.cancellation = cancellation; self.reservation = reservation
        state = Mutex(State(records: records))
    }

    private func inventoryInput(cancellation: CancellationToken) throws -> PreparedSPICESimulation {
        if input.lowered.compiled.captureSourceScalars { return input }
        let cached = try state.withLock { value -> PreparedSPICESimulation? in
            if let inventory = value.inventory { return inventory }
            guard !value.inventoryLoading, !value.finished else {
                throw AnalysisError.invalidConfiguration("Source scalar inventory is busy or closed")
            }
            value.inventoryLoading = true
            return nil
        }
        if let cached { return cached }
        defer { state.withLock { $0.inventoryLoading = false } }
        let controlled = input.checkingResources(CancellationAccounting(original: input.resources, cancellation: cancellation))
        let captured = try SPICESimulationPreparer().reprepare(controlled, captureSourceScalars: true)
        guard captured.configuration.identity == input.configuration.identity,
              captured.sourceInputIdentity == input.sourceInputIdentity else {
            throw AnalysisError.invalidConfiguration("Source inventory capture changed the numerical configuration")
        }
        state.withLock { $0.inventory = captured }
        return captured
    }

    /// Only an actual cancellation cause is normalized; cleanup authority and unrelated failures remain intact.
    private static func isCancellation(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, AnalysisError.cancelled, SPICENativeExecutionError.cancelled,
             SPICESimulationResources.ResourceError.cancelled:
            return true
        case SPICESimulationPreparationError.resource(let cause),
             SPICESimulationPreparationError.source(let cause),
             SPICESimulationPreparationError.parser(let cause),
             SPICESimulationPreparationError.lowering(let cause),
             SPICESimulationPreparationError.options(let cause),
             SPICENativePreparationError.resource(let cause),
             SPICENativePreparationError.compile(let cause),
             SPICENativePreparationError.binding(let cause),
             SPICENativeExecutionError.resource(let cause),
             SPICENativeExecutionError.numerical(let cause),
             SPICENativeExecutionError.binding(let cause):
            return isCancellation(cause)
        case SPICESimulationPreparationError.resolution(_, let cause),
             SPICESimulationPreparationError.condition(_, let cause),
             SPICESimulationPreparationError.diodeResolution(_, let cause, _):
            return cause.map(isCancellation) ?? false
        default:
            // In particular, osdiCleanup is never unwrapped or reduced to its primary cancellation.
            return false
        }
    }

    private static func bindingFailure(_ error: any Error) -> any Error {
        isCancellation(error) ? AnalysisError.cancelled : error
    }

    public func sensitivityParameters(in plan: ExecutionPlan, cancellation: CancellationToken) throws -> [CircuitSensitivityParameter] {
        do { return try sourceParameters(in: plan, cancellation: cancellation) }
        catch { throw Self.bindingFailure(error) }
    }

    private func sourceParameters(in plan: ExecutionPlan, cancellation: CancellationToken) throws -> [CircuitSensitivityParameter] {
        try NativeCircuitExecution.check(cancellation)
        let inventory = try inventoryInput(cancellation: cancellation)
        guard plan.ir.instances.count == input.circuit.instances.count,
              plan.ir.evaluationEnvironment == input.circuit.evaluationEnvironment else {
            throw AnalysisError.invalidConfiguration("Source parameter inventory does not match the circuit")
        }
        for (index, original) in input.circuit.instances.enumerated() {
            let actual = plan.ir.instances[index]
            guard original.name == actual.name, original.typeName == actual.typeName, original.nodes == actual.nodes else {
                throw AnalysisError.invalidConfiguration("Source parameter inventory belongs to another circuit")
            }
        }
        var parameters: [CircuitSensitivityParameter] = []
        for scalar in inventory.lowered.evaluationProvenance.sourceScalars {
            try NativeCircuitExecution.check(cancellation)
            parameters.append(.init(deviceName: scalar.instanceName,
                parameterName: scalar.role.rawValue + "." + scalar.parameterName, nominalValue: scalar.value))
        }
        for name in input.request.osdiInstances.keys.sorted() {
            guard let resolved = input.request.osdiInstances[name],
                  let instance = plan.ir.instances.first(where: { $0.name == name }),
                  case .prepared(let receipt) = instance.osdi,
                  receipt.resolved == resolved else {
                throw AnalysisError.invalidConfiguration("OSDI scalar inventory requires its actual prepared receipt")
            }
            for assignment in resolved.binding.modelParameters + resolved.instanceParameters {
                guard case .real(let value) = assignment.value else { continue }
                guard receipt.resolvedParameters.contains(where: {
                    $0.scope == assignment.scope && $0.parameter.names.contains(assignment.name)
                        && $0.parameter.type == .real && $0.parameter.arrayLength == 0 && $0.isGiven
                }) else { throw AnalysisError.invalidConfiguration("OSDI real source assignment lacks an admitted parameter receipt") }
                let role = assignment.scope == .model ? "model." : "instance."
                parameters.append(.init(deviceName: name, parameterName: role + assignment.name, nominalValue: value))
            }
        }
        return parameters
    }

    private func beginReexecution() throws {
        let previous = try state.withLock { value -> NativeCircuitPreparationRecord? in
            guard !value.finished, value.active == 0, value.activePreparation?.osdiLifetime == nil,
                  value.started < maximumReexecutions else {
                throw AnalysisError.invalidConfiguration("Source reexecution count exceeds admitted capacity")
            }
            value.started += 1; value.active += 1
            let prior = value.activePreparation; value.activePreparation = nil
            return prior
        }
        withExtendedLifetime(previous) {}
    }

    private func sourceInput(plan: ExecutionPlan, instances: [Instance], cancellation: CancellationToken) throws -> PreparedSPICESimulation {
        try NativeCircuitExecution.check(cancellation)
        let inventory = try sensitivityParameters(in: plan, cancellation: cancellation)
        guard instances.count == plan.ir.instances.count else {
            throw AnalysisError.invalidConfiguration("Source scalar patch must preserve instance identity")
        }
        var replacements = input.request.sourceOverrides
        var osdiInstances = input.request.osdiInstances
        for (index, instance) in instances.enumerated() {
            let expected = plan.ir.instances[index]
            guard instance.name == expected.name, instance.typeName == expected.typeName,
                  instance.nodes == expected.nodes else {
                throw AnalysisError.invalidConfiguration("Source scalar patch changed circuit structure")
            }
            for (name, parameter) in instance.parameters {
                guard case .real(let value) = parameter else { continue }
                if case .real(let original) = expected.parameters[name], original == value { continue }
                guard let declared = inventory.first(where: {
                    $0.deviceName == instance.name && $0.parameterName == name
                }) else { throw AnalysisError.invalidConfiguration("Scalar patch is not a supplied source parameter: \(instance.name).\(name)") }
                if declared.nominalValue == value { continue }
                let prefix: String
                let role: NetlistSourceScalarOverride.Role
                if name.hasPrefix("model.") { prefix = "model."; role = .model }
                else if name.hasPrefix("instance.") { prefix = "instance."; role = .instance }
                else { throw AnalysisError.invalidConfiguration("Source scalar patch lacks a parameter role") }
                let parameterName = String(name.dropFirst(prefix.count))
                if let osdi = osdiInstances[instance.name] {
                    let scope: OSDIParameterScope = role == .model ? .model : .instance
                    var models = osdi.binding.modelParameters, values = osdi.instanceParameters
                    let replacement = try OSDIParameterAssignment(name: parameterName, scope: scope, value: .real(value))
                    if scope == .model {
                        guard let slot = models.firstIndex(where: { $0.name == parameterName && $0.scope == scope }) else {
                            throw AnalysisError.invalidConfiguration("OSDI model patch lacks a supplied assignment")
                        }
                        models[slot] = replacement
                    } else {
                        guard let slot = values.firstIndex(where: { $0.name == parameterName && $0.scope == scope }) else {
                            throw AnalysisError.invalidConfiguration("OSDI instance patch lacks a supplied assignment")
                        }
                        values[slot] = replacement
                    }
                    let binding = try OSDIModelBinding(modelName: osdi.binding.modelName, artifact: osdi.binding.artifact,
                        descriptorIndex: osdi.binding.descriptorIndex, expectedDescriptorName: osdi.binding.expectedDescriptorName,
                        modelParameters: models)
                    osdiInstances[instance.name] = try .init(binding: binding, instanceParameters: values, previousState: osdi.previousState)
                } else {
                    let replacement = try NetlistSourceScalarOverride(instanceName: instance.name,
                        parameterName: parameterName, role: role, value: value)
                    replacements.removeAll { $0.instanceName == instance.name && $0.role == role && $0.parameterName == parameterName }
                    replacements.append(replacement)
                }
            }
        }
        let controlled = input.checkingResources(CancellationAccounting(original: input.resources, cancellation: cancellation))
        return try SPICESimulationPreparer().reprepare(controlled, sourceOverrides: replacements,
            captureSourceScalars: false, osdiInstances: osdiInstances)
    }

    private func boundCircuit(_ prepared: consuming PreparedNativeSPICESimulation) throws -> PreparedCircuit {
        var record = prepared.record
        var circuit = prepared.takeCircuit()
        do {
            let bytes = try NativeCircuitExecution.physicalValidationCapacity(record.circuitPreparation)
            if bytes > 0 {
                let reservation = try input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
                circuit = try circuit.addingRetainedStorage(byteCount: bytes, reservation: reservation)
                record = SPICENativeSimulationRecord(input: record.input, circuitPreparation: circuit.record,
                    configurationIdentity: record.configurationIdentity,
                    precisionConfigurationBinding: record.precisionConfigurationBinding,
                    precisionConfigurationFacts: record.precisionConfigurationFacts)
            }
            let (native, devices) = circuit.takeState()
            try NativeCircuitExecution.check(cancellation)
            let evidence = try SPICENativeSourceReexecutionRecord(prepared: record)
            state.withLock { value in value.records.append(evidence); value.activePreparation = record.circuitPreparation }
            return try PreparedCircuit(plan: native.plan, devices: devices, retainingStorage: record)
        } catch { throw NativeCircuitExecution.failure(error, closing: record.circuitPreparation) }
    }

    public func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
        guard input.request.osdiInstances.isEmpty else {
            throw AnalysisError.invalidConfiguration("OSDI source binding requires the asynchronous binding operation")
        }
        try beginReexecution()
        defer { state.withLock { $0.active -= 1 } }
        do {
            let fresh = try sourceInput(plan: plan, instances: instances, cancellation: cancellation)
            return try boundCircuit(SPICENativeSimulation().prepare(fresh, limits: limits))
        } catch { throw Self.bindingFailure(error) }
    }

    public func bind(plan: ExecutionPlan, instances: [Instance], cancellation: CancellationToken) async throws -> PreparedCircuit {
        try beginReexecution()
        defer { state.withLock { $0.active -= 1 } }
        do {
            let fresh = try sourceInput(plan: plan, instances: instances, cancellation: cancellation)
            if let osdi = baselinePreparation?.osdiRuntimeInputs {
                let prepared = try await SPICENativeSimulation().prepare(fresh, limits: limits, osdi: osdi)
                return try boundCircuit(prepared)
            }
            guard fresh.request.osdiInstances.isEmpty else {
                throw AnalysisError.invalidConfiguration("OSDI reexecution requires the exact baseline runtime provider and policies")
            }
            return try boundCircuit(SPICENativeSimulation().prepare(fresh, limits: limits))
        } catch { throw Self.bindingFailure(error) }
    }

    private func preparation(for plan: ExecutionPlan) throws -> NativeCircuitPreparationRecord {
        let latest = state.withLock { $0.activePreparation }
        for candidate in [latest, baselinePreparation] {
            guard let candidate, candidate.plan.topology.variableMap == plan.topology.variableMap,
                  candidate.plan.ir.instances.count == plan.ir.instances.count else { continue }
            var matches = true
            for (index, instance) in plan.ir.instances.enumerated() {
                let expected = candidate.plan.ir.instances[index]
                if instance.name != expected.name || instance.nodes != expected.nodes || instance.osdi?.resolved != expected.osdi?.resolved {
                    matches = false; break
                }
            }
            if matches { return candidate }
        }
        throw AnalysisError.invalidConfiguration("Physical analysis configuration does not match a source-owned preparation")
    }

    public func configureDCAnalysis(_ analysis: DCAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                                    cancellation: CancellationToken) throws -> DCAnalysis {
        guard devices.contains(where: { $0.instance.osdi != nil }) else { return analysis }
        let record = try preparation(for: plan)
        let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
            config: analysis.config, cancellation: cancellation, prior: analysis.physicalResidualValidator)
        var configured = DCAnalysis(config: analysis.config, gminStepping: analysis.gminStepping,
            sourceStepping: analysis.sourceStepping, nodeInitialGuess: analysis.nodeInitialGuess,
            equationPolicy: try .init(rows: validator.rows), physicalResidualValidator: validator,
            completionFinalizer: SourceFinalizer(prior: NativeOSDICompletionFinalizer(record: record, cancellation: cancellation,
                prior: analysis.completionFinalizer), release: { self.releasePreparation(record) }), precisionMode: analysis.precisionMode)
        configured.executionBudget = analysis.executionBudget; configured.resultStorage = analysis.resultStorage
        return configured
    }

    public func configureACAnalysis(_ analysis: ACAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                                    cancellation: CancellationToken) throws -> ACAnalysis {
        guard devices.contains(where: { $0.instance.osdi != nil }) else { return analysis }
        let record = try preparation(for: plan)
        let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
            config: analysis.dcConfig, cancellation: cancellation, prior: analysis.physicalResidualValidator)
        var configured = ACAnalysis(sweep: analysis.sweep, dcConfig: analysis.dcConfig,
            nodeInitialGuess: analysis.nodeInitialGuess, equationPolicy: try .init(rows: validator.rows),
            physicalResidualValidator: validator, completionFinalizer: SourceFinalizer(prior: NativeOSDICompletionFinalizer(record: record,
                cancellation: cancellation, prior: analysis.completionFinalizer), release: { self.releasePreparation(record) }))
        configured.executionBudget = analysis.executionBudget; configured.resultStorage = analysis.resultStorage
        return configured
    }

    private func releasePreparation(_ record: NativeCircuitPreparationRecord) {
        let released = state.withLock { value -> NativeCircuitPreparationRecord? in
            guard let current = value.activePreparation,
                  current.osdiLifetime === record.osdiLifetime else { return nil }
            value.activePreparation = nil
            return current
        }
        withExtendedLifetime(released) {}
    }

    internal func failure(_ error: any Error, closing baseline: NativeCircuitPreparationRecord) -> SPICENativeExecutionError {
        let pending = state.withLock { $0.activePreparation }
        return NativeCircuitExecution.failure(error, closing: [baseline] + (pending.map { [$0] } ?? []))
    }

    private func checkedPatch(_ record: SPICENativeSourceReexecutionRecord, device: String, parameter: String,
                              nominal: Double, value: Double, increment: CompensatedValue) throws {
        guard value.isFinite, nominal.isFinite, increment != .zero,
              try CompensatedValue(high: value).subtracting(CompensatedValue(high: nominal)) == increment else {
            throw SPICENativeExecutionError.invalidOutput
        }
        let role: NetlistSourceScalarOverride.Role
        let name: String
        if parameter.hasPrefix("model.") { role = .model; name = String(parameter.dropFirst(6)) }
        else if parameter.hasPrefix("instance.") { role = .instance; name = String(parameter.dropFirst(9)) }
        else { throw SPICENativeExecutionError.invalidOutput }
        if let osdi = record.osdiInstances[device] {
            let assignments = role == .model ? osdi.binding.modelParameters : osdi.instanceParameters
            guard assignments.contains(where: { $0.name == name && $0.value == .real(value) }) else {
                throw SPICENativeExecutionError.invalidOutput
            }
        } else {
            guard record.sourceOverrides.contains(where: {
                $0.instanceName == device && $0.parameterName == name && $0.role == role && $0.value == value
            }) else { throw SPICENativeExecutionError.invalidOutput }
        }
        let inventory = state.withLock { $0.inventory ?? input }
        if let osdi = inventory.request.osdiInstances[device] {
            let assignments = role == .model ? osdi.binding.modelParameters : osdi.instanceParameters
            guard assignments.contains(where: { $0.name == name && $0.value == .real(nominal) }) else {
                throw SPICENativeExecutionError.invalidOutput
            }
        } else {
            guard inventory.lowered.evaluationProvenance.sourceScalars.contains(where: {
                $0.instanceName == device && $0.parameterName == name && $0.role == role && $0.value == nominal
            }) else { throw SPICENativeExecutionError.invalidOutput }
        }
    }

    private func checkedNode(_ node: Node, baseline: Node, in record: SPICENativeSourceReexecutionRecord) throws {
        let source = baselinePreparation?.plan.ir ?? input.circuit
        if baseline == source.groundNode {
            guard node == record.preparation.plan.ir.groundNode else { throw SPICENativeExecutionError.invalidOutput }
            return
        }
        guard let name = source.nodeNames[baseline],
              record.preparation.plan.ir.nodeNames[node] == name,
              record.preparation.plan.topology.variableMap[.nodeVoltage(node)] != nil else {
            throw SPICENativeExecutionError.invalidOutput
        }
    }

    private func completedPhase(_ record: SPICENativeSourceReexecutionRecord, analysis: String,
                                points: Int, reservation: NativeExecutionStorage) throws -> NativeCircuitExecutionFacts {
        let policy: DCEquationPolicy?
        if record.preparation.osdiRuntimeInputs != nil {
            policy = try NativeOSDIPhysicalValidator.policy(record: record.preparation,
                config: record.configuration.options.convergence)
        } else { policy = nil }
        return .init(record: record.preparation, instances: record.preparation.plan.ir.instances,
            analysis: analysis, completedPointCount: points, reservation: reservation, equationPolicy: policy)
    }

    internal func finishReexecutions(matching result: SensitivityResult,
                                    reservation outputReservation: NativeExecutionStorage) throws -> SPICENativeSourceReexecutionLedger {
        let records = try preparedRecords()
        guard records.count == result.sensitivities.count, let baselineNode = result.outputNode,
              result.baselineOutput != nil else { throw SPICENativeExecutionError.invalidOutput }
        var completed: [SPICENativeSourceReexecutionCompletion] = []; completed.reserveCapacity(records.count)
        for (index, entry) in result.sensitivities.enumerated() {
            guard let value = entry.perturbedValue, let increment = entry.effectiveIncrement,
                  let output = entry.perturbedOutput, let node = entry.outputNode else { throw SPICENativeExecutionError.invalidOutput }
            let record = records[index]
            try checkedPatch(record, device: entry.deviceName, parameter: entry.parameterName,
                nominal: entry.nominalValue, value: value, increment: increment)
            try checkedNode(node, baseline: baselineNode, in: record)
            completed.append(.init(deviceName: entry.deviceName, parameterName: entry.parameterName,
                nominalValue: entry.nominalValue, perturbedValue: value, effectiveIncrement: increment,
                observation: .dc(output: output, node: node),
                completedPhase: try completedPhase(record, analysis: "op", points: 1, reservation: outputReservation),
                preparedSource: record))
        }
        let source = state.withLock { $0.inventory ?? input }
        return .init(source: source, records: completed, reservation: reservation)
    }

    internal func finishReexecutions(matching result: ACSensitivityResult,
                                    reservation outputReservation: NativeExecutionStorage) throws -> SPICENativeSourceReexecutionLedger {
        let records = try preparedRecords()
        guard records.count == result.sensitivities.count, let baselineNode = result.outputPositiveNode else {
            throw SPICENativeExecutionError.invalidOutput
        }
        var completed: [SPICENativeSourceReexecutionCompletion] = []; completed.reserveCapacity(records.count)
        for (index, entry) in result.sensitivities.enumerated() {
            guard let value = entry.perturbedValue, let increment = entry.effectiveIncrement,
                  let outputs = entry.perturbedValues, let node = entry.outputPositiveNode,
                  outputs.count == result.frequencies.count else { throw SPICENativeExecutionError.invalidOutput }
            let record = records[index]
            try checkedPatch(record, device: entry.deviceName, parameter: entry.parameterName,
                nominal: entry.nominalValue, value: value, increment: increment)
            try checkedNode(node, baseline: baselineNode, in: record)
            if let baselineReference = result.outputReferenceNode {
                guard let reference = entry.outputReferenceNode else { throw SPICENativeExecutionError.invalidOutput }
                try checkedNode(reference, baseline: baselineReference, in: record)
            } else if entry.outputReferenceNode != nil { throw SPICENativeExecutionError.invalidOutput }
            completed.append(.init(deviceName: entry.deviceName, parameterName: entry.parameterName,
                nominalValue: entry.nominalValue, perturbedValue: value, effectiveIncrement: increment,
                observation: .ac(outputs: outputs, frequencies: result.frequencies, positiveNode: node, referenceNode: entry.outputReferenceNode),
                completedPhase: try completedPhase(record, analysis: "ac", points: outputs.count, reservation: outputReservation),
                preparedSource: record))
        }
        let source = state.withLock { $0.inventory ?? input }
        return .init(source: source, records: completed, reservation: reservation)
    }

    /// Freezes the bounded preparation ledger only for the successful result join.
    private func preparedRecords() throws -> [SPICENativeSourceReexecutionRecord] {
        try state.withLock { value in
            guard value.active == 0, !value.inventoryLoading, value.activePreparation?.osdiLifetime == nil else {
                throw AnalysisError.invalidConfiguration("Source reexecution or foreign cleanup is still active")
            }
            value.finished = true
            return value.records
        }
    }
}
