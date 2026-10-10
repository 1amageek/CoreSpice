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
        if input.circuit.instances.contains(where: { $0.mos != nil }) {
            try validateMOSConditions(input: input, limits: limits)
        }
        let circuit = try NativeCircuitPreparer().prepare(ir: input.circuit,
            registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources)
        let common = circuit.record
        let plan = common.plan
        let resources = input.resources
        let identity = try SPICEPreparationEncoding.digest(domain: "CoreSpice.native-configuration.v1",
            maximumBytes: input.maximumTransformBytes, resources: resources) { encoding in
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
            for instance in plan.ir.instances {
                if case .prepared(let receipt) = instance.mos {
                    try encodeMOS(receipt, input: input, encoding: &encoding)
                }
            }
        }
        try resources.checkCancellation()
        let record = SPICENativeSimulationRecord(input: input, circuitPreparation: common,
            configurationIdentity: identity)
        return PreparedNativeSPICESimulation(record: record, circuit: circuit)
    }
    public func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput {
        do { return try await checkedExecute(prepared, cancellation: cancellation) }
        catch { throw NativeCircuitExecution.failure(error) }
    }
    private func checkedExecute(_ prepared: consuming PreparedNativeSPICESimulation,
                                cancellation: CancellationToken) async throws -> SPICENativeSimulationOutput {
        try NativeCircuitExecution.check(cancellation)
        let record = prepared.record
        let input = record.input, plan = record.plan, config = input.configuration
        let circuit = prepared.takeCircuit()
        let solver = SparseLUSolver()
        var guesses: [Node: Double] = [:]; guesses.reserveCapacity(input.nodeSets.bindings.count)
        for binding in input.nodeSets.bindings { guesses[binding.node] = binding.voltage }
        let waveform: WaveformData
        let statistics: TransientExecutionStatistics
        let reservation: SPICESourceStorageReservation
        switch config.analysis {
        case .op:
            let run = try await DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            waveform = WaveformData.from(dcResult: run.result, topology: plan.topology.circuitTopology, title: "Operating Point")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation
        case .dc(let source, let values, _):
            let run = try await DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
                .runSweep(circuit: circuit, source: source, values: values, solver: solver,
                    observer: nil, cancellation: cancellation)
            waveform = WaveformData.from(sweepResult: run.result,
                topology: plan.topology.circuitTopology, title: "DC Sweep")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation
        case .transient(let transient):
            let run = try await TransientAnalysis(config: transient, convergenceConfig: config.options.convergence)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            waveform = try WaveformData.from(transientResult: run.result, topology: plan.topology.circuitTopology, title: "Transient")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation
        }
        try NativeCircuitExecution.check(cancellation)
        guard waveform.pointCount > 0 else { throw SPICENativeExecutionError.invalidOutput }
        let pointCount: Int
        if case .dc(_, let values, _) = config.analysis { pointCount = values.count }
        else { pointCount = waveform.pointCount }
        var receipts: [SPICENativeModelReceipt] = []; receipts.reserveCapacity(plan.ir.instances.count)
        for instance in plan.ir.instances {
            try NativeCircuitExecution.check(cancellation)
            receipts.append(.init(instanceName: instance.name, deviceType: instance.typeName,
                model: instance.model, mosPreparation: {
                    if case .prepared(let receipt) = instance.mos { return receipt }
                    return nil
                }(), completedPointCount: pointCount))
        }
        return SPICENativeSimulationOutput(prepared: record, waveform: waveform, executedModels: receipts,
                                           statistics: statistics, reservation: reservation)
    }
}
