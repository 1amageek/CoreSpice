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

    /// Node voltages to analyze (output nodes).
    public let outputNodes: [Node]

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
        self.outputNodes = outputNodes
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
            let period = 1.0 / fundamentalFrequency
            let variableMap = plan.topology.variableMap

            var allHarmonics: [String: [FourierResult.HarmonicComponent]] = [:]
            var allTHD: [String: Double] = [:]

            for node in outputNodes {
                guard let varIndex = variableMap[.nodeVoltage(node)] else { continue }
                let varName = "V(\(node.id))"

                // Extract time-value pairs for the last period
                let waveform = Self.extractLastPeriod(
                    timePoints: transientResult.timePoints,
                    values: transientResult.solutions.map { $0[varIndex] },
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
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            throw error
        }
    }

    // MARK: - Public Computation Helpers

    /// Extracts the data points within the last period of the simulation.
    public static func extractLastPeriod(
        timePoints: [Double],
        values: [Double],
        period: Double
    ) -> [(time: Double, value: Double)] {
        guard let lastTime = timePoints.last else { return [] }
        let periodStart = lastTime - period

        var result: [(time: Double, value: Double)] = []
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
