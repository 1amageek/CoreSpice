import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation

/// Fourier (.four) analysis.
///
/// Performs a transient analysis and then computes the Fourier decomposition
/// of selected output variables over the final period. The analysis extracts
/// harmonic magnitudes, phases, and total harmonic distortion (THD).
///
/// The DFT is computed using trapezoidal integration for each harmonic:
/// ```
/// X_k = (2/T) * integral of x(t) * exp(-j*2*pi*k*f0*t) dt
/// ```
///
/// This computes specific harmonic coefficients without requiring FFT.
public struct FourierAnalysis: Analysis, Sendable {

    public typealias Result = FourierResult

    /// The fundamental frequency in Hz.
    public let fundamentalFrequency: Double

    /// Number of harmonics to compute (including the fundamental).
    public let harmonicCount: Int

    /// MNA variables to analyze.
    public let outputs: [FourierOutput]

    /// Transient configuration for the underlying simulation.
    public let transientConfig: TransientConfig

    /// Convergence configuration for the DC operating point and NR iterations.
    public let convergenceConfig: ConvergenceConfig

    public init(
        fundamentalFrequency: Double,
        harmonicCount: Int = 9,
        outputNodes: [Node],
        transientConfig: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.fundamentalFrequency = fundamentalFrequency
        self.harmonicCount = harmonicCount
        self.outputs = outputNodes.map {
            FourierOutput(variable: .nodeVoltage($0), name: "V(\($0.id))")
        }
        self.transientConfig = transientConfig
        self.convergenceConfig = convergenceConfig
    }

    public init(
        fundamentalFrequency: Double,
        harmonicCount: Int = 9,
        outputs: [FourierOutput],
        transientConfig: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.fundamentalFrequency = fundamentalFrequency
        self.harmonicCount = harmonicCount
        self.outputs = outputs
        self.transientConfig = transientConfig
        self.convergenceConfig = convergenceConfig
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> FourierResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .fourier,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            guard fundamentalFrequency.isFinite, fundamentalFrequency > 0 else {
                throw AnalysisError.invalidConfiguration(
                    "Fourier fundamental frequency must be positive and finite"
                )
            }
            guard harmonicCount >= 1 else {
                throw AnalysisError.invalidConfiguration(
                    "Fourier harmonic count must be at least one"
                )
            }
            guard !outputs.isEmpty else {
                throw AnalysisError.invalidConfiguration(
                    "Fourier analysis requires at least one output node"
                )
            }
            let period = 1.0 / fundamentalFrequency
            guard transientConfig.stopTime >= period else {
                throw AnalysisError.invalidConfiguration(
                    "Transient stop time must cover at least one Fourier period"
                )
            }
            for output in outputs {
                guard plan.topology.variableMap[output.variable] != nil else {
                    throw AnalysisError.invalidConfiguration(
                        "Fourier output \(output.name) not found in variable map"
                    )
                }
            }

            // Phase 1: Run transient analysis
            let transientAnalysis = TransientAnalysis(
                config: transientConfig,
                convergenceConfig: convergenceConfig
            )
            let transientResult = try await transientAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )

            // Phase 2: Extract the final period and compute Fourier coefficients
            let variableMap = plan.topology.variableMap

            var allHarmonics: [String: [FourierResult.HarmonicComponent]] = [:]
            var allTHD: [String: Double] = [:]

            for output in outputs {
                guard let varIndex = variableMap[output.variable] else {
                    throw AnalysisError.internalError(
                        "Validated Fourier output \(output.name) disappeared from variable map"
                    )
                }
                let varName = output.name

                // Extract time-value pairs for the last period
                let waveform = Self.extractLastPeriod(
                    timePoints: transientResult.timePoints,
                    values: try transientResult.solutionTrace.column(variableIndex: varIndex),
                    period: period
                )

                guard waveform.count >= 2 else {
                    throw AnalysisError.invalidConfiguration(
                        "Insufficient data points in the final period for Fourier analysis"
                    )
                }

                // Compute harmonics
                let components = computeHarmonics(waveform: waveform, period: period)
                allHarmonics[varName] = components

                // Compute THD
                let fundamental = components.first(where: { $0.harmonic == 1 })?.magnitude ?? 0
                if fundamental > 1e-30 {
                    var sumSquared = 0.0
                    for comp in components where comp.harmonic >= 2 {
                        sumSquared += comp.magnitude * comp.magnitude
                    }
                    allTHD[varName] = sqrt(sumSquared) / fundamental * 100.0
                } else {
                    allTHD[varName] = 0.0
                }
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .fourier,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return FourierResult(
                fundamentalFrequency: fundamentalFrequency,
                harmonics: allHarmonics,
                thd: allTHD,
                transientResult: transientResult
            )
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
                type: .fourier,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Public Computation Helpers

    /// Extracts the data points within the last period of the simulation.
    public static func extractLastPeriod<Values: Collection>(
        timePoints: [Double],
        values: Values,
        period: Double
    ) -> [(time: Double, value: Double)] where Values.Element == Double, Values.Index == Int {
        guard let lastTime = timePoints.last else { return [] }
        let periodStart = lastTime - period

        var result: [(time: Double, value: Double)] = []
        result.reserveCapacity(timePoints.count)
        for (i, t) in timePoints.enumerated() {
            if t >= periodStart {
                result.append((time: t, value: values[i]))
            }
        }
        return result
    }

    /// Computes Fourier harmonic coefficients using trapezoidal integration.
    ///
    /// For each harmonic k (0..harmonicCount):
    /// ```
    /// a_k = (2/T) * integral of x(t) * cos(2*pi*k*f0*t) dt
    /// b_k = (2/T) * integral of x(t) * sin(2*pi*k*f0*t) dt
    /// X_k = sqrt(a_k^2 + b_k^2)
    /// phase_k = atan2(-b_k, a_k)
    /// ```
    public func computeHarmonics(
        waveform: [(time: Double, value: Double)],
        period: Double
    ) -> [FourierResult.HarmonicComponent] {
        var components: [FourierResult.HarmonicComponent] = []

        // DC component (harmonic 0)
        let dc = trapezoidalIntegrate(waveform: waveform) { _, value in value } / period
        var fundamentalMagnitude = 0.0

        for k in 0...harmonicCount {
            let freq = Double(k) * fundamentalFrequency
            let omega = 2.0 * .pi * Double(k) * fundamentalFrequency

            let ak: Double
            let bk: Double

            if k == 0 {
                ak = dc
                bk = 0
            } else {
                // Cosine coefficient
                ak = (2.0 / period) * trapezoidalIntegrate(waveform: waveform) { t, v in
                    v * cos(omega * t)
                }
                // Sine coefficient
                bk = (2.0 / period) * trapezoidalIntegrate(waveform: waveform) { t, v in
                    v * sin(omega * t)
                }
            }

            let magnitude = k == 0 ? abs(ak) : sqrt(ak * ak + bk * bk)
            let phase = k == 0 ? 0.0 : atan2(-bk, ak) * 180.0 / .pi

            if k == 1 {
                fundamentalMagnitude = magnitude
            }

            let normalized: Double
            if fundamentalMagnitude > 1e-30 {
                normalized = magnitude / fundamentalMagnitude
            } else {
                normalized = k == 0 ? 0.0 : 0.0
            }

            components.append(FourierResult.HarmonicComponent(
                harmonic: k,
                frequency: freq,
                magnitude: magnitude,
                phase: phase,
                normalizedMagnitude: normalized
            ))
        }

        return components
    }

    /// Computes the trapezoidal integral of f(t, v) over the waveform data.
    private func trapezoidalIntegrate(
        waveform: [(time: Double, value: Double)],
        function: (Double, Double) -> Double
    ) -> Double {
        guard waveform.count >= 2 else { return 0 }

        var integral = 0.0
        for i in 1..<waveform.count {
            let t0 = waveform[i - 1].time
            let t1 = waveform[i].time
            let f0 = function(t0, waveform[i - 1].value)
            let f1 = function(t1, waveform[i].value)
            integral += 0.5 * (f0 + f1) * (t1 - t0)
        }
        return integral
    }
}
