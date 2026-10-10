import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceAnalysis
import CoreSpiceEvent
import CoreSpiceWaveform

public struct SPICENativeSimulation: SPICENativePreparing, SPICENativeExecuting {
    public init() {}
    public func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits)
        throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation {
        do { return try checkedPrepare(input, limits: limits) }
        catch let error as SPICENativePreparationError { throw error }
        catch { throw .resource(error) }
    }
    private func checkedPrepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits) throws -> PreparedNativeSPICESimulation {
        guard limits.maximumDeviceCount > 0, limits.maximumMatrixDimension > 0,
              limits.maximumAllocationBytes > 0 else { throw SPICENativePreparationError.invalidLimits }
        let originalCircuit = input.circuit
        var mosCount = 0
        for instance in originalCircuit.instances {
            if instance.mos != nil || instance.typeName.hasPrefix("nmos_") || instance.typeName.hasPrefix("pmos_") {
                guard case .resolved = instance.mos else { throw SPICENativePreparationError.mosBinding(.missingPreparedReceipt) }
                mosCount += 1
            }
        }
        if mosCount > 0 { try validateMOSConditions(input: input, limits: limits) }
        let circuit = originalCircuit
        guard circuit.instances.count <= limits.maximumDeviceCount else { throw SPICENativePreparationError.capacityExceeded }
        let (baseDimension, overflow) = circuit.nodes.count.addingReportingOverflow(circuit.branches.count)
        guard !overflow, baseDimension > 0 else { throw SPICENativePreparationError.capacityExceeded }
        let auxiliaryUpper = try multiply(UInt64(mosCount), 8)
        let dimensionUpper = try add(UInt64(baseDimension), auxiliaryUpper)
        guard let upperDimension = Int(exactly: dimensionUpper) else { throw SPICENativePreparationError.capacityExceeded }
        guard upperDimension > 0, upperDimension <= limits.maximumMatrixDimension,
              upperDimension <= input.configuration.numericalLimits.maximumMatrixDimension else {
            throw SPICENativePreparationError.capacityExceeded
        }
        let square = try multiply(UInt64(upperDimension), UInt64(upperDimension))
        // Dense LU plus sparse factors, ordering/adjacency/tree workspaces and topology copies.
        let topologyBytes = try add(try multiply(square, 256),
            try multiply(try add(UInt64(circuit.instances.count), UInt64(upperDimension)), 4096))
        let mosRetainedBytes = try multiply(UInt64(mosCount), limits.mosPreparationLimits?.maximumRetainedBytes ?? 0)
        let mosTemporaryBytes = try multiply(UInt64(mosCount), limits.mosPreparationLimits?.maximumTemporaryBytes ?? 0)
        let compileBytes = try add(topologyBytes, mosRetainedBytes)
        let outputBytes = try multiply(UInt64(input.configuration.numericalLimits.maximumSavedScalars), 32)
        let executionBytes = try add(compileBytes, outputBytes)
        guard executionBytes <= limits.maximumAllocationBytes else { throw SPICENativePreparationError.capacityExceeded }
        let resources = input.resources
        try resources.checkCancellation()
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: compileBytes)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: try add(topologyBytes, mosTemporaryBytes))
        defer { withExtendedLifetime(scratch) {} }
        try resources.charge(.retainedElements, units: try multiply(square, UInt64(upperDimension)))
        var mosOwners = UniqueArray<NativePreparedMOSDevice?>()
        mosOwners.reserveCapacity(circuit.instances.count)
        let preparedCircuit = try prepareMOSCircuit(circuit, input: input, limits: limits, owners: &mosOwners)
        let plan: ExecutionPlan
        do { plan = try StandardCompiler().compile(ir: preparedCircuit) }
        catch { throw SPICENativePreparationError.compile(error) }
        try resources.checkCancellation()
        let devices: [any BoundDevice]
        do { devices = try bind(plan: plan, input: input, mosOwners: &mosOwners) }
        catch let error as MOSBindingFailure { throw SPICENativePreparationError.mosBinding(error) }
        catch { throw SPICENativePreparationError.binding(error) }
        // Admit the concrete numerical topology before executing or publishing the prepared owner.
        _ = try TransientExecutionBudget(limits: input.configuration.numericalLimits,
            dimension: plan.topology.dimension, nonZeroCount: plan.matrixStructure.nonZeroCount,
            deviceCount: circuit.instances.count)
        var encoding = try SPICEPreparationEncoding(domain: "CoreSpice.native-configuration.v1",
            maximumBytes: input.maximumTransformBytes, resources: resources)
        try encoding.field(input.configuration.identity.hexadecimalValue)
        try encoding.field("CoreSpice.NativeCPU.op-dc-tran.v1")
        try encoding.field("CoreSpice.SparseLU.Accelerate.v1")
        try encoding.integer(UInt64(limits.maximumDeviceCount)); try encoding.integer(UInt64(limits.maximumMatrixDimension))
        try encoding.integer(limits.maximumAllocationBytes)
        for instance in plan.ir.instances {
            try encoding.field(instance.name); try encoding.field(instance.typeName)
            try encoding.field(instance.model?.name ?? "")
            if let declaration = instance.model?.declarationID,
               let origin = input.netlist.models.first(where: { $0.origin?.declarationID == declaration })?.origin,
               let source = input.sources.first(where: { $0.binding.key == origin.captureID }) {
                try encoding.field(source.binding.reference.digest.hexadecimalValue)
                try encoding.integer(origin.occurrenceID?.rawValue ?? 0)
                try encoding.integer(origin.statementByteOffset ?? UInt64(origin.location.line))
                try encoding.integer(UInt64(origin.ordinal))
            } else { try encoding.field("") }
        }
        var mosReceipts: [MOSPreparationReceipt] = []
        mosReceipts.reserveCapacity(mosCount)
        for instance in plan.ir.instances {
            if case .prepared(let receipt) = instance.mos {
                try encodeMOS(receipt, input: input, encoding: &encoding)
                mosReceipts.append(receipt)
            }
        }
        let identity = try encoding.digest()
        try resources.checkCancellation()
        let record = SPICENativeSimulationRecord(input: input, plan: plan, limits: limits,
            configurationIdentity: identity, executionCapacity: executionBytes,
            mosPreparationReceipts: mosReceipts, reservation: reservation)
        return PreparedNativeSPICESimulation(record: record, devices: devices)
    }
    public func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput {
        let (record, devices) = prepared.takeExecutionState()
        do {
            return try await withTaskCancellationHandler {
                try await checkedExecute(record, devices: devices, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
        } catch let error as SPICENativeExecutionError { throw error }
        catch let error as AnalysisError {
            if case .cancelled = error { throw .cancelled }
            throw .numerical(error)
        } catch is CancellationError { throw .cancelled }
        catch { throw .numerical(error) }
    }
    private func checkedExecute(_ prepared: SPICENativeSimulationRecord, devices initialDevices: [any BoundDevice], cancellation: CancellationToken) async throws -> SPICENativeSimulationOutput {
        try check(cancellation)
        let input = prepared.input, plan = prepared.plan, config = input.configuration
        var devices = initialDevices
        let reservation: SPICESourceStorageReservation
        do { reservation = try input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: prepared.executionCapacity) }
        catch { throw SPICENativeExecutionError.resource(error) }
        let solver = SparseLUSolver()
        let budget = try TransientExecutionBudget(limits: config.numericalLimits, dimension: plan.topology.dimension,
            nonZeroCount: plan.matrixStructure.nonZeroCount, deviceCount: plan.ir.instances.count)
        var guesses: [Node: Double] = [:]; guesses.reserveCapacity(input.nodeSets.bindings.count)
        for binding in input.nodeSets.bindings { guesses[binding.node] = binding.voltage }
        let waveform: WaveformData
        let statistics: TransientExecutionStatistics
        switch config.analysis {
        case .op:
            var dc = DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
            dc.executionBudget = budget
            try budget.admitSavedPoint(accepted: false)
            let result = try await dc.run(plan: plan, devices: devices, solver: solver, observer: nil, cancellation: cancellation)
            waveform = WaveformData.from(dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")
            statistics = budget.statistics
        case .dc(let source, let values, _):
            var results: [DCResult] = []; results.reserveCapacity(values.count)
            for value in values {
                try check(cancellation)
                try budget.admitSavedPoint(accepted: false)
                do { try replaceSource(plan: plan, input: input, name: source, value: value, devices: &devices) }
                catch { throw SPICENativeExecutionError.binding(error) }
                var dc = DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
                dc.executionBudget = budget
                results.append(try await dc.run(plan: plan, devices: devices, solver: solver, observer: nil, cancellation: cancellation))
            }
            waveform = WaveformData.from(sweepResult: SweepResult(parameterName: source, values: values, results: results),
                topology: plan.topology.circuitTopology, title: "DC Sweep")
            statistics = budget.statistics
        case .transient(let transient):
            let result = try await TransientAnalysis(config: transient, convergenceConfig: config.options.convergence)
                .run(plan: plan, devices: devices, solver: solver, observer: nil, cancellation: cancellation)
            guard result.timePoints.last == transient.stopTime, let actual = result.executionStatistics else {
                throw SPICENativeExecutionError.invalidOutput
            }
            waveform = try WaveformData.from(transientResult: result, topology: plan.topology.circuitTopology, title: "Transient")
            statistics = actual
        }
        try check(cancellation)
        guard waveform.pointCount > 0 else { throw SPICENativeExecutionError.invalidOutput }
        let pointCount: Int
        if case .dc(_, let values, _) = config.analysis { pointCount = values.count }
        else { pointCount = waveform.pointCount }
        var receipts: [SPICENativeModelReceipt] = []; receipts.reserveCapacity(plan.ir.instances.count)
        for instance in plan.ir.instances {
            try check(cancellation)
            receipts.append(.init(instanceName: instance.name, deviceType: instance.typeName,
                model: instance.model, mosPreparation: {
                    if case .prepared(let receipt) = instance.mos { return receipt }
                    return nil
                }(), completedPointCount: pointCount))
        }
        return SPICENativeSimulationOutput(prepared: prepared, waveform: waveform, executedModels: receipts,
                                           statistics: statistics, reservation: reservation)
    }
    private func context(plan: ExecutionPlan, input: PreparedSPICESimulation) throws -> BindingContext {
        let structure = plan.matrixStructure
        return BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames, operatingConditions: try input.configuration.options.operatingConditions(),
            stampIndexResolver: { row, column in structure.index(row: row, col: column) })
    }
    private func bind(plan: ExecutionPlan, input: PreparedSPICESimulation,
                      mosOwners: inout UniqueArray<NativePreparedMOSDevice?>) throws -> [any BoundDevice] {
        var context = try context(plan: plan, input: input)
        var registry = DeviceRegistry()
        registry.register(ResistorDescriptor()); registry.register(CapacitorDescriptor()); registry.register(InductorDescriptor())
        registry.register(VoltageSourceDescriptor()); registry.register(CurrentSourceDescriptor())
        var devices: [any BoundDevice] = []; devices.reserveCapacity(plan.ir.instances.count)
        for (index, instance) in plan.ir.instances.enumerated() {
            try input.resources.checkCancellation()
            if let owner = mosOwners[index].take() {
                devices.append(try owner.bind(instance: instance, context: &context))
            } else {
                guard instance.mos == nil, let descriptor = registry.descriptor(for: instance.typeName) else {
                    throw SPICENativePreparationError.unsupportedCapability(instance.typeName)
                }
                devices.append(try descriptor.bind(instance: instance, context: &context))
            }
        }
        return devices
    }
    private func replaceSource(plan: ExecutionPlan, input: PreparedSPICESimulation, name: String, value: Double,
                               devices: inout [any BoundDevice]) throws {
        guard let index = plan.ir.instances.firstIndex(where: { $0.name == name }) else {
            throw SPICENativeExecutionError.binding(MOSBindingFailure.identityMismatch)
        }
        let instance = plan.ir.instances[index]
        guard instance.typeName == "vsource" || instance.typeName == "isource", instance.mos == nil else {
            throw SPICENativeExecutionError.binding(MOSBindingFailure.identityMismatch)
        }
        var parameters = instance.parameters
        parameters[instance.typeName == "vsource" ? "v" : "i"] = .real(value)
        let replacement = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
            parameters: parameters, model: instance.model, mos: instance.mos, modelConsumption: instance.modelConsumption,
            ownedNodes: instance.ownedNodes, ownedBranches: instance.ownedBranches,
            referencedBranches: instance.referencedBranches, referencedNodes: instance.referencedNodes,
            opticalNodes: instance.opticalNodes)
        var context = try context(plan: plan, input: input)
        if instance.typeName == "vsource" { devices[index] = try VoltageSourceDescriptor().bind(instance: replacement, context: &context) }
        else { devices[index] = try CurrentSourceDescriptor().bind(instance: replacement, context: &context) }
    }
    private func check(_ cancellation: CancellationToken) throws {
        if cancellation.isCancelled || Task.isCancelled { throw SPICENativeExecutionError.cancelled }
    }
    private func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw SPICENativePreparationError.capacityExceeded }; return value
    }
    private func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw SPICENativePreparationError.capacityExceeded }; return value
    }
}
