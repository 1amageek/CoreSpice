import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceAnalysis
import CoreSpiceEvent
import CoreSpiceWaveform
import CoreSpiceOSDI

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
        if input.circuit.instances.contains(where: { $0.diode != nil }) {
            try validateDiodeConditions(input: input, limits: limits)
        }
        let circuit = try NativeCircuitPreparer().prepare(ir: input.circuit,
            registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources)
        return try finishPreparation(input, limits: limits, circuit: circuit)
    }
    public func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits,
                        osdi: SPICEOSDIRuntimeInputs) async throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation {
        do {
            let circuit = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(), limits: limits,
                numericalLimits: input.configuration.numericalLimits, resources: input.resources, osdi: osdi)
            return try finishPreparation(input, limits: limits, circuit: circuit)
        } catch let error as SPICENativePreparationError { throw error }
        catch { throw .resource(error) }
    }
    private func finishPreparation(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits,
                                   circuit: consuming PreparedNativeCircuit) throws -> PreparedNativeSPICESimulation {
        var circuit = consume circuit
        var common = circuit.record
        let plan = common.plan
        let resources = input.resources
        do {
        let legacyIdentity = try SPICEPreparationEncoding.digest(domain: SPICENativeSimulationRecord.configurationDomain(for: common),
            maximumBytes: input.maximumTransformBytes, resources: resources) { encoding in
            try encoding.field(input.configuration.identity.hexadecimalValue)
            try encoding.field(SPICENativeSimulationRecord.algorithmIdentity(for: common, analysis: input.configuration.analysis))
            try encoding.field(SparseLUSolver.implementationIdentity)
            try encoding.integer(UInt64(limits.maximumDeviceCount)); try encoding.integer(UInt64(limits.maximumMatrixDimension))
            try encoding.integer(limits.maximumAllocationBytes)
            try encodeDiodePolicy(limits, encoding: &encoding)
            if let osdi = common.osdiRuntimeInputs { try encodeOSDI(osdi, records: common.osdiPreparationRecords, encoding: &encoding) }
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
                if case .prepared(let receipt) = instance.diode {
                    try encodeDiode(receipt, input: input, encoding: &encoding)
                }
            }
        }
        let binding: NativePrecisionConfigurationBinding?
        let facts: NativePrecisionConfigurationFacts?
        let identity: ContentDigest
        let precisionTransient: Bool
        switch input.configuration.analysis { case .transient, .fourier: precisionTransient = true; default: precisionTransient = false }
        if common.osdiRuntimeInputs?.transientPrecision != nil, precisionTransient {
            let bytes = try NativePrecisionConfigurationFacts.metadataByteCount(input: input, common: common)
            let (capacity, overflow) = common.compileCapacity.addingReportingOverflow(bytes)
            guard !overflow, capacity <= limits.maximumAllocationBytes else { throw SPICENativePreparationError.capacityExceeded }
            let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
            circuit = try circuit.addingRetainedStorage(byteCount: bytes, reservation: reservation)
            common = circuit.record
            let actual = try NativePrecisionConfigurationFacts.prepared(input: input, common: common, reservation: reservation)
            let actualBinding = NativePrecisionConfigurationBinding(legacyBaseDigest: legacyIdentity)
            identity = try NativePrecisionConfigurationVerification().identity(actual, binding: actualBinding,
                maximumEncodingBytes: input.maximumTransformBytes, resources: resources)
            binding = actualBinding; facts = actual
        } else { binding = nil; facts = nil; identity = legacyIdentity }
        try resources.checkCancellation()
        let record = SPICENativeSimulationRecord(input: input, circuitPreparation: common,
            configurationIdentity: identity, precisionConfigurationBinding: binding, precisionConfigurationFacts: facts)
        return PreparedNativeSPICESimulation(record: record, circuit: circuit)
        } catch {
            if let lifetime = common.osdiLifetime {
                do { try lifetime.close() }
                catch let secondary { throw SPICENativePreparationError.osdiCleanup(.init(primary: error, secondary: secondary,
                    lifetime: lifetime, reservations: common.reservations)) }
            }
            throw error
        }
    }
    public func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput {
        try await execute(prepared, cancellation: cancellation, executionResources: nil)
    }
    public func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken,
                        executionResources: AnalysisExecutionResources?)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput {
        let record = prepared.record.circuitPreparation
        do { return try await checkedExecute(prepared, cancellation: cancellation, executionResources: executionResources) }
        catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
    private func checkedExecute(_ prepared: consuming PreparedNativeSPICESimulation,
                                cancellation: CancellationToken, executionResources: AnalysisExecutionResources?) async throws -> SPICENativeSimulationOutput {
        try NativeCircuitExecution.check(cancellation)
        let record = prepared.record
        let input = record.input, plan = record.plan, config = input.configuration
        let circuit: PreparedNativeCircuit
        if let executionResources { circuit = try prepared.takeCircuit().usingExecutionResources(executionResources) }
        else { circuit = prepared.takeCircuit() }
        let solver = SparseLUSolver()
        var guesses: [Node: Double] = [:]; guesses.reserveCapacity(input.nodeSets.bindings.count)
        for binding in input.nodeSets.bindings { guesses[binding.node] = binding.voltage }
        let waveform: WaveformData
        let statistics: TransientExecutionStatistics
        let reservation: NativeExecutionStorage
        let phases: [NativeCircuitExecutionFacts]
        var operatingPoint: DCResult?
        var dcSweepResult: SweepResult<DCResult>?
        var transientResult: TransientResult?
        var networkResult: NetworkParameterResult?
        var tfResult: TransferFunctionResult?
        var sensitivityResult: SensitivityResult?
        var acSensitivityResult: ACSensitivityResult?
        var poleZeroResult: PoleZeroResult?
        var fourierResult: FourierResult?
        var noiseResult: NoiseResult?
        let thermal = Set(record.circuitPreparation.osdiVariableKinds.compactMap { variable, kind -> Node? in
            guard kind == .thermalPotential, case .nodeVoltage(let node) = variable else { return nil }; return node
        })
        let layout = try WaveformVariableLayout(validatingVariableMap: plan.topology.variableMap,
            topology: plan.topology.circuitTopology, temperatureRiseNodes: thermal)
        switch config.analysis {
        case .network(let frequencies, let ports, let limits):
            let run = try await NetworkParameterAnalysis(frequencies: frequencies, ports: ports, limits: limits,
                dcConfig: config.options.convergence, nodeInitialGuess: guesses)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            networkResult = run.result; operatingPoint = run.result.operatingPoint
            waveform = .from(networkResult: run.result, title: "Network Parameters")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .transferFunction(let output, let source):
            let run = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: source,
                dcConfig: config.options.convergence).run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            tfResult = run.result; operatingPoint = run.result.dcOperatingPoint
            waveform = .from(transferFunctionResult: run.result, title: "Transfer Function")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .poleZero(let input, let output, let reference, let includePoles, let includeZeros):
            let run = try await PoleZeroAnalysis(input: input, outputPositiveNode: output, outputReferenceNode: reference,
                dcConfig: config.options.convergence).run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            let filtered = try PoleZeroResult(poles: includePoles ? run.result.poles : [],
                zeros: includeZeros ? run.result.zeros : [], dcGain: run.result.dcGain, variableMap: run.result.variableMap)
                .retainingStorage(run.reservation)
            poleZeroResult = filtered
            waveform = .from(poleZeroResult: filtered, title: "Pole-Zero")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .fourier(let frequency, let outputs, let transient):
            let run = try await FourierAnalysis(fundamentalFrequency: frequency, outputs: outputs,
                transientConfig: transient, convergenceConfig: config.options.convergence)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            fourierResult = run.result; transientResult = run.result.transientResult
            operatingPoint = run.result.transientResult.operatingPoint
            waveform = .from(fourierResult: run.result, title: "Fourier")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .sensitivity(let output, let ac):
            let binding = try NativeSourceCircuitDeviceBinding(input: input, limits: record.limits,
                maximumReexecutions: NativeSourceCircuitDeviceBinding.sensitivityCapacity(input), cancellation: cancellation,
                baselinePreparation: record.circuitPreparation)
            if let ac {
                let run = try await ACSensitivityAnalysis(outputPositiveNode: output, sweep: ac,
                    dcConfig: config.options.convergence, nodeInitialGuess: guesses, deviceBinding: binding)
                    .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
                acSensitivityResult = run.result; operatingPoint = run.result.operatingPoint
                waveform = .from(acSensitivityResult: run.result, title: "AC Sensitivity")
                guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
                statistics = actual; reservation = run.reservation; phases = run.phases
            } else {
                let run = try await SensitivityAnalysis(outputNode: output, dcConfig: config.options.convergence, nodeInitialGuess: guesses,
                    deviceBinding: binding).run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
                sensitivityResult = run.result; operatingPoint = run.result.dcOperatingPoint
                waveform = .from(sensitivityResult: run.result, title: "Sensitivity")
                guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
                statistics = actual; reservation = run.reservation; phases = run.phases
            }
        case .op:
            let run = try await DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            operatingPoint = run.result
            waveform = try WaveformData.from(dcResult: run.result, variableLayout: layout, title: "Operating Point")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .dc(let source, let values, _):
            let run = try await DCAnalysis(config: config.options.convergence, nodeInitialGuess: guesses)
                .runSweep(circuit: circuit, source: source, values: values, solver: solver,
                    observer: nil, cancellation: cancellation)
            dcSweepResult = run.result
            waveform = WaveformData.from(sweepResult: run.result,
                topology: plan.topology.circuitTopology, title: "DC Sweep")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .transient(let transient):
            let run = try await TransientAnalysis(config: transient, convergenceConfig: config.options.convergence)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            operatingPoint = run.result.operatingPoint; transientResult = run.result
            waveform = try WaveformData.from(transientResult: run.result, variableLayout: layout, title: "Transient")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .ac(let sweep):
            let run = try await ACAnalysis(sweep: sweep, dcConfig: config.options.convergence, nodeInitialGuess: guesses)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            operatingPoint = run.result.operatingPoint
            waveform = try WaveformData.from(acResult: run.result, variableLayout: layout, title: "AC")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        case .noise(let output, let reference, let source, let sweep):
            let run = try await NoiseAnalysis(outputNode: output, outputReferenceNode: reference, inputSourceName: source,
                sweep: sweep, dcConfig: config.options.convergence, nodeInitialGuess: guesses)
                .run(circuit: circuit, solver: solver, observer: nil, cancellation: cancellation)
            operatingPoint = run.result.operatingPoint; noiseResult = run.result
            waveform = WaveformData.from(noiseResult: run.result, title: "Noise")
            guard let actual = run.statistics else { throw SPICENativeExecutionError.invalidOutput }
            statistics = actual; reservation = run.reservation; phases = run.phases
        }
        try NativeCircuitExecution.check(cancellation)
        guard waveform.pointCount > 0 else { throw SPICENativeExecutionError.invalidOutput }
        let pointCount: Int
        if case .dc(_, let values, _) = config.analysis { pointCount = values.count }
        else { pointCount = waveform.pointCount }
        var receipts: [SPICENativeModelReceipt] = []; receipts.reserveCapacity(plan.ir.instances.count)
        for instance in plan.ir.instances {
            try NativeCircuitExecution.check(cancellation)
            let selectedModelIdentifier: String?
            if let resolved = instance.diode?.resolved {
                selectedModelIdentifier = try input.lowered.compiled.modelName(for: resolved)
            } else if let resolved = instance.osdi?.resolved {
                selectedModelIdentifier = resolved.binding.modelName
            } else {
                selectedModelIdentifier = instance.model?.name
            }
            receipts.append(.init(instanceName: instance.name, deviceType: instance.typeName,
                model: instance.model, mosPreparation: {
                    if case .prepared(let receipt) = instance.mos { return receipt }
                    return nil
                }(), osdiPreparation: record.osdiPreparationRecords.first { $0.instanceName == instance.name }, diodePreparation: {
                    if case .prepared(let receipt) = instance.diode { return receipt }
                    return nil
                }(), selectedModelIdentifier: selectedModelIdentifier, completedPointCount: pointCount))
        }
        if let facts = record.precisionConfigurationFacts {
            guard phases.allSatisfy({ NativePrecisionConfigurationVerification.policiesMatch($0.equationPolicy, facts.equationPolicy) }) else {
                throw SPICENativeExecutionError.invalidOutput
            }
        }
        let storedDCResult: SPICENativeStoredDCResult?
        if let dcSweepResult, dcSweepResult.results.allSatisfy({ $0.opticalState == nil }) {
            storedDCResult = try .init(sweep: dcSweepResult)
        } else if case .op = config.analysis, let operatingPoint, operatingPoint.opticalState == nil {
            storedDCResult = try .init(operatingPoint: operatingPoint)
        } else { storedDCResult = nil }
        return SPICENativeSimulationOutput(prepared: record, waveform: waveform, executedModels: receipts,
                                           statistics: statistics, reservation: reservation, operatingPoint: operatingPoint,
                                           dcSweepResult: dcSweepResult, storedDCResult: storedDCResult, transientResult: transientResult, noiseResult: noiseResult, phases: phases, networkResult: networkResult, tfResult: tfResult, sensitivityResult: sensitivityResult,
                                           acSensitivityResult: acSensitivityResult, poleZeroResult: poleZeroResult, fourierResult: fourierResult)
    }
}
