import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation

/// Noise (.noise) analysis.
///
/// Computes the output-referred noise spectral density at a specified
/// output node over a frequency range. The analysis:
///
/// 1. Finds the DC operating point.
/// 2. At each frequency, builds the AC network matrix.
/// 3. For each device noise source, computes the transfer function
///    from the noise source to the output by solving the AC system
///    with a unit current injection.
/// 4. Accumulates independent `|H_i|² S_i` and device output-referred channels,
///    including correlated complex amplitudes. Each device follows one path.
/// 5. Optionally computes input-referred noise and integrated RMS noise.
public struct NoiseAnalysis: Analysis, Sendable {

    public typealias Result = NoiseResult

    /// The output node for noise measurement.
    public let outputNode: Node

    /// Optional reference node for differential output noise.
    public let outputReferenceNode: Node?

    /// The name of the input source (for input-referred noise calculation).
    public let inputSourceName: String?

    /// The frequency sweep specification.
    public let sweep: FrequencySweep

    /// DC convergence configuration.
    public let dcConfig: ConvergenceConfig

    public init(
        outputNode: Node,
        outputReferenceNode: Node? = nil,
        inputSourceName: String? = nil,
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.outputNode = outputNode
        self.outputReferenceNode = outputReferenceNode
        self.inputSourceName = inputSourceName
        self.sweep = sweep
        self.dcConfig = dcConfig
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> NoiseResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap
        let frequencies = try sweep.frequencies()

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .noise,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            guard frequencies.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw AnalysisError.invalidConfiguration("Noise frequencies must be finite and positive")
            }
            for device in devices {
                if let admission = device as? any NoiseAnalysisAdmissionDevice {
                    try admission.validateNoiseAnalysis()
                }
            }
            // Phase 1: DC operating point
            let dcAnalysis = DCAnalysis(config: dcConfig)
            let dcResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )
            let dcState = SolutionState(
                variables: dcResult.variables,
                variableMap: variableMap
            )
            let dcOpticalState = dcResult.opticalState ?? OpticalState()

            guard let outputIndex = variableMap[.nodeVoltage(outputNode)] else {
                throw AnalysisError.invalidConfiguration(
                    "Output node \(outputNode.id) not found in variable map"
                )
            }
            let outputReferenceIndex = outputReferenceNode.flatMap {
                variableMap[.nodeVoltage($0)]
            }
            if let outputReferenceNode,
               outputReferenceNode != plan.ir.groundNode,
               outputReferenceIndex == nil {
                throw AnalysisError.invalidConfiguration(
                    "Output reference node \(outputReferenceNode.id) not found in variable map"
                )
            }
            let inputStimulus = try inputSourceName.map {
                try inputSourceStimulus(named: $0, plan: plan, variableMap: variableMap)
            }

            // Collect noisy devices
            let outputNoisyDevices = devices.compactMap { $0 as? any OutputReferredNoisyDevice }
            // A correlated device is counted through its output-referred path once.
            let noisyDevices = devices.filter { !($0 is any OutputReferredNoisyDevice) }
                .compactMap { $0 as? any NoisyDevice }
            let transferNodes = Set(outputNoisyDevices.flatMap(\.noiseTransferNodes)).sorted { $0.id < $1.id }
            for node in transferNodes where node != plan.ir.groundNode {
                guard variableMap[.nodeVoltage(node)] != nil else { throw NoiseTransferError.unknownNode(node) }
            }

            // Initialize per-source contribution tracking
            struct SourceTracker {
                let deviceName: String
                let noiseName: String
                let positiveNode: Node
                let negativeNode: Node
                var spectralDensity: [Double] = []
            }
            var sourceTrackers: [SourceTracker] = []
            var outputTrackers: [SourceTracker] = []
            var transferValues: [Node: NoiseTransferGain] = [:]
            transferValues.reserveCapacity(transferNodes.count)

            var outputNoiseDensity: [Double] = []
            var inputReferredNoiseDensity: [Double] = []

            // Phase 2: Frequency sweep
            var complexSolver = ComplexSparseLUSolver()
            var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)
            var rhs = [ComplexPair](repeating: ComplexPair(), count: dim)

            // Pre-allocate buffers for the inner noise solve loop
            var noiseRHS = [ComplexPair](repeating: ComplexPair(), count: dim)
            var noiseSolutionBuf = [ComplexPair](repeating: ComplexPair(), count: dim)
            var inputRHS = [ComplexPair](repeating: ComplexPair(), count: dim)
            var inputSolutionBuf = [ComplexPair](repeating: ComplexPair(), count: dim)

            for (freqIdx, freq) in frequencies.enumerated() {
                if cancellation.isCancelled {
                    throw AnalysisError.cancelled
                }

                let omega = 2.0 * .pi * freq

                // Build AC matrix Y = G + jωC
                matrix.clear()
                for i in 0..<dim { rhs[i] = ComplexPair() }

                var stamper = ComplexMatrixStamper(
                    variableMap: variableMap,
                    stampMatrix: { row, col, re, im in
                        matrix.addValue(row: row, col: col, value: ComplexPair(real: re, imag: im))
                    },
                    stampRHS: { row, re, im in
                        rhs[row] = ComplexPair(
                            real: rhs[row].real + re,
                            imag: rhs[row].imag + im
                        )
                    }
                )

                for device in devices {
                    if let optoDevice = device as? OptoelectronicDevice {
                        optoDevice.stampAC(into: &stamper, state: dcState, opticalState: dcOpticalState, omega: omega)
                    } else {
                        try device.stampAC(into: &stamper, state: dcState, omega: omega)
                    }
                }

                // Add Gmin to diagonal
                for i in 0..<dim {
                    matrix.addValue(row: i, col: i, value: ComplexPair(real: dcConfig.gmin, imag: 0))
                }

                do {
                    try complexSolver.factorize(matrix: matrix)
                } catch {
                    throw AnalysisError.singularMatrix
                }

                // Phase 3: For each noise source, compute transfer function
                var totalNoisePSD = 0.0
                var trackerIdx = 0

                for noisyDevice in noisyDevices {
                    let contributions = try noiseContributions(
                        for: noisyDevice, state: dcState,
                        opticalState: dcOpticalState, frequency: freq
                    )

                    for source in contributions {
                        guard source.currentSpectralDensity.isFinite, source.currentSpectralDensity >= 0 else {
                            throw AnalysisError.invalidConfiguration("Invalid noise PSD from \(noisyDevice.instance.name)/\(source.name)")
                        }
                        for node in [source.positiveNode, source.negativeNode] {
                            guard node == plan.ir.groundNode || variableMap[.nodeVoltage(node)] != nil else {
                                throw AnalysisError.invalidConfiguration("Unknown noise node from \(noisyDevice.instance.name)/\(source.name)")
                            }
                        }
                        if freqIdx == 0 {
                            sourceTrackers.append(SourceTracker(deviceName: noisyDevice.instance.name,
                                noiseName: source.name, positiveNode: source.positiveNode, negativeNode: source.negativeNode))
                        }
                        guard trackerIdx < sourceTrackers.count,
                              sourceTrackers[trackerIdx].deviceName == noisyDevice.instance.name,
                              sourceTrackers[trackerIdx].noiseName == source.name,
                              sourceTrackers[trackerIdx].positiveNode == source.positiveNode,
                              sourceTrackers[trackerIdx].negativeNode == source.negativeNode else {
                            throw AnalysisError.invalidConfiguration("Noise source identity changed during sweep")
                        }
                        // Clear and set RHS with unit current injection at noise source nodes
                        for i in 0..<dim { noiseRHS[i] = ComplexPair() }

                        let posIdx = variableMap[.nodeVoltage(source.positiveNode)]
                        let negIdx = variableMap[.nodeVoltage(source.negativeNode)]

                        if let posIdx {
                            noiseRHS[posIdx].real += 1.0
                        }
                        if let negIdx {
                            noiseRHS[negIdx].real -= 1.0
                        }

                        // Solve for transfer function: Y * v = i_noise
                        do {
                            try complexSolver.solve(rhs: noiseRHS, into: &noiseSolutionBuf)
                        } catch {
                            throw AnalysisError.internalError(
                                "Failed to solve noise transfer function: \(error)"
                            )
                        }

                        // Transfer function H(f) = V_out for unit current injection
                        let reference = outputReferenceIndex.map {
                            noiseSolutionBuf[$0]
                        } ?? ComplexPair()
                        let hReal = noiseSolutionBuf[outputIndex].real - reference.real
                        let hImag = noiseSolutionBuf[outputIndex].imag - reference.imag
                        let hMagSquared = hReal * hReal + hImag * hImag

                        // Output noise contribution = |H(f)|² × S_n(f)
                        let contribution = hMagSquared * source.currentSpectralDensity
                        totalNoisePSD += contribution

                        sourceTrackers[trackerIdx].spectralDensity.append(contribution)
                        trackerIdx += 1
                    }
                }

                // Original correlated models consume full complex H(node), retaining
                // relative phase. One factorization serves every unit injection.
                transferValues.removeAll(keepingCapacity: true)
                for node in transferNodes {
                    if cancellation.isCancelled { throw AnalysisError.cancelled }
                    if node == plan.ir.groundNode { continue }
                    guard let nodeIndex = variableMap[.nodeVoltage(node)] else { throw NoiseTransferError.unknownNode(node) }
                    for index in 0..<dim { noiseRHS[index] = ComplexPair() }
                    noiseRHS[nodeIndex].real = 1
                    try complexSolver.solve(rhs: noiseRHS, into: &noiseSolutionBuf)
                    let reference = outputReferenceIndex.map { noiseSolutionBuf[$0] } ?? ComplexPair()
                    transferValues[node] = NoiseTransferGain(real: noiseSolutionBuf[outputIndex].real - reference.real,
                        imaginary: noiseSolutionBuf[outputIndex].imag - reference.imag)
                }
                let gains = try NoiseTransferGains(values: transferValues)
                var outputTrackerIndex = 0
                for device in outputNoisyDevices {
                    if cancellation.isCancelled { throw AnalysisError.cancelled }
                    let channels = try device.outputNoiseContributions(state: dcState, frequency: freq, gains: gains)
                    guard Set(channels.map(\.name)).count == channels.count else {
                        throw AnalysisError.invalidConfiguration("Duplicate output noise channel from \(device.instance.name)")
                    }
                    for channel in channels {
                        let contribution = channel.outputSpectralDensity
                        guard contribution.isFinite, contribution >= 0 else {
                            throw AnalysisError.invalidConfiguration("Invalid output noise PSD from \(device.instance.name)/\(channel.name)")
                        }
                        if freqIdx == 0 {
                            outputTrackers.append(SourceTracker(deviceName: device.instance.name, noiseName: channel.name,
                                positiveNode: plan.ir.groundNode, negativeNode: plan.ir.groundNode))
                        }
                        guard outputTrackerIndex < outputTrackers.count,
                              outputTrackers[outputTrackerIndex].deviceName == device.instance.name,
                              outputTrackers[outputTrackerIndex].noiseName == channel.name else {
                            throw AnalysisError.invalidConfiguration("Output noise channel identity changed during sweep")
                        }
                        outputTrackers[outputTrackerIndex].spectralDensity.append(contribution)
                        outputTrackerIndex += 1
                        totalNoisePSD += contribution
                    }
                }
                guard outputTrackerIndex == outputTrackers.count else {
                    throw AnalysisError.invalidConfiguration("Output noise channel count changed during sweep")
                }

                guard trackerIdx == sourceTrackers.count else {
                    throw AnalysisError.invalidConfiguration("Noise source count changed during sweep")
                }
                outputNoiseDensity.append(totalNoisePSD)

                if let inputStimulus {
                    for i in 0..<dim { inputRHS[i] = ComplexPair() }
                    inputStimulus.stamp(into: &inputRHS)

                    do {
                        try complexSolver.solve(rhs: inputRHS, into: &inputSolutionBuf)
                    } catch {
                        throw AnalysisError.internalError(
                            "Failed to solve noise input transfer function: \(error)"
                        )
                    }

                    let reference = outputReferenceIndex.map {
                        inputSolutionBuf[$0]
                    } ?? ComplexPair()
                    let gain = ComplexPair(
                        real: inputSolutionBuf[outputIndex].real - reference.real,
                        imag: inputSolutionBuf[outputIndex].imag - reference.imag
                    )
                    let gainMagnitudeSquared = gain.real * gain.real + gain.imag * gain.imag
                    guard gainMagnitudeSquared.isFinite, gainMagnitudeSquared > 1.0e-30 else {
                        throw AnalysisError.invalidConfiguration(
                            "Input source '\(inputStimulus.sourceName)' has zero transfer to output node \(outputNode.id)"
                        )
                    }
                    inputReferredNoiseDensity.append(totalNoisePSD / gainMagnitudeSquared)
                } else {
                    inputReferredNoiseDensity.append(totalNoisePSD)
                }


                // Progress
                let fraction = Double(freqIdx + 1) / Double(frequencies.count)
                await observer?.emit(.progressUpdate(try ProgressInfo(
                    id: analysisID,
                    fraction: fraction,
                    message: "Noise: f = \(freq) Hz"
                )))
            }

            // Integrate noise over frequency using trapezoidal rule
            let integratedNoise = integrateNoise(
                frequencies: frequencies,
                noiseDensity: outputNoiseDensity
            )

            // Build device contributions
            let deviceContributions = (sourceTrackers + outputTrackers).map { tracker in
                NoiseResult.DeviceNoiseContribution(
                    deviceName: tracker.deviceName,
                    noiseName: tracker.noiseName,
                    spectralDensity: tracker.spectralDensity
                )
            }

            if cancellation.isCancelled { throw AnalysisError.cancelled }
            let result = try NoiseResult(
                frequencies: frequencies,
                outputNoiseDensity: outputNoiseDensity,
                inputReferredNoiseDensity: inputReferredNoiseDensity,
                integratedOutputNoise: integratedNoise,
                deviceContributions: deviceContributions,
                variableMap: variableMap
            )

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .noise,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return result
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError,
               case .cancelled = analysisError {
                status = .cancelled
            } else {
                status = .failed
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .noise,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Private

    private enum InputSourceStimulus {
        case voltageSource(name: String, branchIndex: Int)
        case currentSource(name: String, positiveIndex: Int?, negativeIndex: Int?)

        var sourceName: String {
            switch self {
            case .voltageSource(let name, _), .currentSource(let name, _, _):
                name
            }
        }

        func stamp(into rhs: inout [ComplexPair]) {
            switch self {
            case .voltageSource(_, let branchIndex):
                rhs[branchIndex] = ComplexPair(real: 1.0, imag: 0.0)
            case .currentSource(_, let positiveIndex, let negativeIndex):
                if let positiveIndex {
                    rhs[positiveIndex] = ComplexPair(
                        real: rhs[positiveIndex].real - 1.0,
                        imag: rhs[positiveIndex].imag
                    )
                }
                if let negativeIndex {
                    rhs[negativeIndex] = ComplexPair(
                        real: rhs[negativeIndex].real + 1.0,
                        imag: rhs[negativeIndex].imag
                    )
                }
            }
        }
    }

    private func inputSourceStimulus(
        named sourceName: String,
        plan: ExecutionPlan,
        variableMap: [MNAVariable: Int]
    ) throws -> InputSourceStimulus {
        let branchAllocatingTypes: Set<String> = [
            "vsource", "inductor", "vcvs", "ccvs", "cccs", "ccvs_ref", "cswitch"
        ]
        var branchID = 0
        var matches: [InputSourceStimulus] = []

        for instance in plan.ir.instances {
            let typeName = instance.typeName.lowercased()
            if instance.name.caseInsensitiveCompare(sourceName) == .orderedSame {
                switch typeName {
                case "vsource":
                    let branch = Branch(id: branchID)
                    guard let branchIndex = variableMap[.branchCurrent(branch)] else {
                        throw AnalysisError.invalidConfiguration(
                            "Branch for input source '\(sourceName)' not found in variable map"
                        )
                    }
                    matches.append(.voltageSource(name: instance.name, branchIndex: branchIndex))
                case "isource":
                    let positiveIndex = variableMap[.nodeVoltage(instance.nodes[0])]
                    let negativeIndex = variableMap[.nodeVoltage(instance.nodes[1])]
                    guard positiveIndex != nil || negativeIndex != nil else {
                        throw AnalysisError.invalidConfiguration(
                            "Input source '\(sourceName)' is connected only to ground"
                        )
                    }
                    matches.append(.currentSource(
                        name: instance.name,
                        positiveIndex: positiveIndex,
                        negativeIndex: negativeIndex
                    ))
                default:
                    throw AnalysisError.invalidConfiguration(
                        "Input source '\(sourceName)' resolved to unsupported device type \(instance.typeName); expected independent voltage or current source"
                    )
                }
            }

            if typeName == "ccvs" {
                branchID += 2
            } else if branchAllocatingTypes.contains(typeName) {
                branchID += 1
            }
        }

        if matches.count == 1 {
            return matches[0]
        }
        if matches.isEmpty {
            let available = plan.ir.instances
                .filter { ["vsource", "isource"].contains($0.typeName.lowercased()) }
                .map(\.name)
                .sorted()
                .joined(separator: ", ")
            throw AnalysisError.invalidConfiguration(
                "Input source '\(sourceName)' not found in circuit; available sources: \(available)"
            )
        }
        throw AnalysisError.invalidConfiguration(
            "Input source '\(sourceName)' matched multiple independent sources"
        )
    }

    /// Returns noise contributions for a device, using optical state when available.
    ///
    /// If the device conforms to `OptoelectronicDevice`, the optical-aware
    /// overload is called so that optical-power-dependent noise (e.g.,
    /// photodiode shot noise `2q(I_photo + I_dark)`) uses the actual
    /// DC optical power rather than zero.
    private func noiseContributions(
        for device: any NoisyDevice,
        state: SolutionState,
        opticalState: OpticalState,
        frequency: Double
    ) throws -> [NoiseSource] {
        if let optoDevice = device as? OptoelectronicDevice {
            return optoDevice.noiseContributions(
                state: state, opticalState: opticalState, frequency: frequency
            )
        }
        return try device.noiseContributions(state: state, frequency: frequency)
    }

    /// Integrates noise spectral density over frequency using the trapezoidal rule.
    /// Returns RMS noise in Vrms.
    private func integrateNoise(frequencies: [Double], noiseDensity: [Double]) -> Double {
        guard frequencies.count >= 2 else {
            return 0
        }

        var integral = 0.0
        for i in 1..<frequencies.count {
            let df = frequencies[i] - frequencies[i - 1]
            let avg = (noiseDensity[i] + noiseDensity[i - 1]) / 2.0
            integral += avg * df
        }
        return sqrt(integral)
    }
}
