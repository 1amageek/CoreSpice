import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
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
        let circuit = input.circuit
        guard circuit.instances.count <= limits.maximumDeviceCount else { throw SPICENativePreparationError.capacityExceeded }
        let (upperDimension, overflow) = circuit.nodes.count.addingReportingOverflow(circuit.branches.count)
        guard !overflow, upperDimension > 0, upperDimension <= limits.maximumMatrixDimension,
              upperDimension <= input.configuration.numericalLimits.maximumMatrixDimension else {
            throw SPICENativePreparationError.capacityExceeded
        }
        let square = try multiply(UInt64(upperDimension), UInt64(upperDimension))
        // Dense LU plus sparse factors, ordering/adjacency/tree workspaces and topology copies.
        // Linear two-port devices have at most one branch; no expansion or device-private nodes.
        let compileBytes = try add(try multiply(square, 256), try multiply(UInt64(circuit.instances.count + upperDimension), 4096))
        let outputBytes = try multiply(UInt64(input.configuration.numericalLimits.maximumSavedScalars), 32)
        let executionBytes = try add(compileBytes, outputBytes)
        guard executionBytes <= limits.maximumAllocationBytes else { throw SPICENativePreparationError.capacityExceeded }
        let resources = input.resources
        try resources.checkCancellation()
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: compileBytes)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: compileBytes)
        defer { withExtendedLifetime(scratch) {} }
        try resources.charge(.retainedElements, units: try multiply(square, UInt64(upperDimension)))
        let plan: ExecutionPlan
        do { plan = try StandardCompiler().compile(ir: circuit) }
        catch { throw SPICENativePreparationError.compile(error) }
        try resources.checkCancellation()
        // Preparation verifies real descriptor bindings; mutable devices are discarded here.
        do { _ = try bind(plan: plan, input: input, override: nil) }
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
        let identity = try encoding.digest()
        try resources.checkCancellation()
        return PreparedNativeSPICESimulation(input: input, plan: plan, limits: limits,
            configurationIdentity: identity, executionCapacity: executionBytes, reservation: reservation)
    }
    public func execute(_ prepared: PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput {
        do {
            return try await withTaskCancellationHandler {
                try await checkedExecute(prepared, cancellation: cancellation)
            } onCancel: { cancellation.cancel() }
        } catch let error as SPICENativeExecutionError { throw error }
        catch let error as AnalysisError {
            if case .cancelled = error { throw .cancelled }
            throw .numerical(error)
        } catch is CancellationError { throw .cancelled }
        catch { throw .numerical(error) }
    }
    private func checkedExecute(_ prepared: PreparedNativeSPICESimulation, cancellation: CancellationToken) async throws -> SPICENativeSimulationOutput {
        try check(cancellation)
        let input = prepared.input, plan = prepared.plan, config = input.configuration
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
            let devices = try bind(plan: plan, input: input, override: nil)
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
                let devices = try bind(plan: plan, input: input, override: (source, value))
                var dc = DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
                dc.executionBudget = budget
                results.append(try await dc.run(plan: plan, devices: devices, solver: solver, observer: nil, cancellation: cancellation))
            }
            waveform = WaveformData.from(sweepResult: SweepResult(parameterName: source, values: values, results: results),
                topology: plan.topology.circuitTopology, title: "DC Sweep")
            statistics = budget.statistics
        case .transient(let transient):
            let devices = try bind(plan: plan, input: input, override: nil)
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
                model: instance.model, completedPointCount: pointCount))
        }
        return SPICENativeSimulationOutput(prepared: prepared, waveform: waveform, executedModels: receipts,
                                           statistics: statistics, reservation: reservation)
    }
    private func bind(plan: ExecutionPlan, input: PreparedSPICESimulation, override: (String, Double)?) throws -> [any BoundDevice] {
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames, operatingConditions: try input.configuration.options.operatingConditions(),
            stampIndexResolver: { row, column in structure.index(row: row, col: column) })
        var registry = DeviceRegistry()
        registry.register(ResistorDescriptor()); registry.register(CapacitorDescriptor()); registry.register(InductorDescriptor())
        registry.register(VoltageSourceDescriptor()); registry.register(CurrentSourceDescriptor())
        var devices: [any BoundDevice] = []; devices.reserveCapacity(plan.ir.instances.count)
        for instance in plan.ir.instances {
            try input.resources.checkCancellation()
            let resolved: Instance
            if let override, override.0 == instance.name {
                var parameters = instance.parameters
                parameters[instance.typeName == "vsource" ? "v" : "i"] = .real(override.1)
                resolved = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                    parameters: parameters, model: instance.model, modelConsumption: instance.modelConsumption, ownedNodes: instance.ownedNodes,
                    ownedBranches: instance.ownedBranches, referencedBranches: instance.referencedBranches,
                    referencedNodes: instance.referencedNodes, opticalNodes: instance.opticalNodes)
            } else { resolved = instance }
            guard let descriptor = registry.descriptor(for: resolved.typeName) else {
                throw SPICENativePreparationError.unsupportedCapability(resolved.typeName)
            }
            devices.append(try descriptor.bind(instance: resolved, context: &context))
        }
        return devices
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
