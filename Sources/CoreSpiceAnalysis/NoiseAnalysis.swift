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
/// 4. Accumulates the output noise: `S_out(f) = Σ |H_i(f)|² × S_n_i(f)`.
/// 5. Optionally computes input-referred noise and integrated RMS noise.
public struct NoiseAnalysis: Analysis, Sendable {

    public typealias Result = NoiseResult

    /// The output node for noise measurement.
    public let outputNode: Node

    /// The name of the input source (for input-referred noise calculation).
    public let inputSourceName: String?

    /// The frequency sweep specification.
    public let sweep: FrequencySweep

    /// DC convergence configuration.
    public let dcConfig: ConvergenceConfig

    public init(
        outputNode: Node,
        inputSourceName: String? = nil,
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.outputNode = outputNode
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
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap
        let frequencies = sweep.frequencies()

        observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .noise,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
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

            // Collect noisy devices
            let noisyDevices = devices.compactMap { $0 as? any NoisyDevice }

            // Initialize per-source contribution tracking
            struct SourceTracker {
                let deviceName: String
                let noiseName: String
                var spectralDensity: [Double] = []
            }
            var sourceTrackers: [SourceTracker] = []

            // Pre-populate trackers from first frequency point
            if let firstFreq = frequencies.first {
                for noisyDevice in noisyDevices {
                    let contributions = noiseContributions(
                        for: noisyDevice, state: dcState,
                        opticalState: dcOpticalState, frequency: firstFreq
                    )
                    for source in contributions {
                        sourceTrackers.append(SourceTracker(
                            deviceName: noisyDevice.instance.name,
                            noiseName: source.name
                        ))
                    }
                }
            }

            var outputNoiseDensity: [Double] = []
            var inputReferredNoiseDensity: [Double] = []

            // Phase 2: Frequency sweep
            var complexSolver = ComplexSparseLUSolver()
            var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)
            var rhs = [ComplexPair](repeating: ComplexPair(), count: dim)

            // Pre-allocate buffers for the inner noise solve loop
            var noiseRHS = [ComplexPair](repeating: ComplexPair(), count: dim)
            var noiseSolutionBuf = [ComplexPair](repeating: ComplexPair(), count: dim)

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
                        device.stampAC(into: &stamper, state: dcState, omega: omega)
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
                    let contributions = noiseContributions(
                        for: noisyDevice, state: dcState,
                        opticalState: dcOpticalState, frequency: freq
                    )

                    for source in contributions {
                        // Clear and set RHS with unit current injection at noise source nodes
                        for i in 0..<dim { noiseRHS[i] = ComplexPair() }

                        let posIdx = variableMap[.nodeVoltage(source.positiveNode)]
                        let negIdx = variableMap[.nodeVoltage(source.negativeNode)]

                        if let posIdx {
                            noiseRHS[posIdx] = ComplexPair(real: 1.0, imag: 0.0)
                        }
                        if let negIdx {
                            noiseRHS[negIdx] = ComplexPair(real: -1.0, imag: 0.0)
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
                        let hReal = noiseSolutionBuf[outputIndex].real
                        let hImag = noiseSolutionBuf[outputIndex].imag
                        let hMagSquared = hReal * hReal + hImag * hImag

                        // Output noise contribution = |H(f)|² × S_n(f)
                        let contribution = hMagSquared * source.currentSpectralDensity
                        totalNoisePSD += contribution

                        if trackerIdx < sourceTrackers.count {
                            sourceTrackers[trackerIdx].spectralDensity.append(contribution)
                        }
                        trackerIdx += 1
                    }
                }

                outputNoiseDensity.append(totalNoisePSD)

                // Input-referred noise (placeholder: divide by 1 if no input source)
                inputReferredNoiseDensity.append(totalNoisePSD)

                // Progress
                let fraction = Double(freqIdx + 1) / Double(frequencies.count)
                observer?.emit(.progressUpdate(ProgressInfo(
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
            let deviceContributions = sourceTrackers.map { tracker in
                NoiseResult.DeviceNoiseContribution(
                    deviceName: tracker.deviceName,
                    noiseName: tracker.noiseName,
                    spectralDensity: tracker.spectralDensity
                )
            }

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .noise,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return NoiseResult(
                frequencies: frequencies,
                outputNoiseDensity: outputNoiseDensity,
                inputReferredNoiseDensity: inputReferredNoiseDensity,
                integratedOutputNoise: integratedNoise,
                deviceContributions: deviceContributions,
                variableMap: variableMap
            )
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError,
               case .cancelled = analysisError {
                status = .cancelled
            } else {
                status = .failed
            }

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .noise,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            throw error
        }
    }

    // MARK: - Private

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
    ) -> [NoiseSource] {
        if let optoDevice = device as? OptoelectronicDevice {
            return optoDevice.noiseContributions(
                state: state, opticalState: opticalState, frequency: frequency
            )
        }
        return device.noiseContributions(state: state, frequency: frequency)
    }

    /// Integrates noise spectral density over frequency using the trapezoidal rule.
    /// Returns RMS noise in Vrms.
    private func integrateNoise(frequencies: [Double], noiseDensity: [Double]) -> Double {
        guard frequencies.count >= 2 else {
            if let first = noiseDensity.first, let f = frequencies.first {
                return sqrt(first * f)
            }
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
