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
/// Each harmonic analytically integrates the piecewise-linear transient waveform:
/// ```
/// X_k = (2/T) * integral of x(t) * exp(-j*2*pi*k*f0*t) dt
/// ```
///
/// This computes specific harmonic coefficients without requiring FFT.
public struct FourierAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?
    package var preparedTransientAnalysis: TransientAnalysis?

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
    public let completionFinalizer: (any AnalysisCompletionFinalizing)?

    public init(
        fundamentalFrequency: Double,
        harmonicCount: Int = 9,
        outputNodes: [Node],
        transientConfig: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig(),
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil
    ) {
        self.fundamentalFrequency = fundamentalFrequency
        self.harmonicCount = harmonicCount
        self.outputs = outputNodes.map {
            FourierOutput(variable: .nodeVoltage($0), name: "V(\($0.id))")
        }
        self.transientConfig = transientConfig
        self.convergenceConfig = convergenceConfig
        self.completionFinalizer = completionFinalizer
    }

    public init(
        fundamentalFrequency: Double,
        harmonicCount: Int = 9,
        outputs: [FourierOutput],
        transientConfig: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig(),
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil
    ) {
        self.fundamentalFrequency = fundamentalFrequency
        self.harmonicCount = harmonicCount
        self.outputs = outputs
        self.transientConfig = transientConfig
        self.convergenceConfig = convergenceConfig
        self.completionFinalizer = completionFinalizer
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
            let componentCount = try TransientExecutionBudget.add(harmonicCount, 1, "Fourier component count")
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
            var transientAnalysis = preparedTransientAnalysis ?? TransientAnalysis(
                config: transientConfig,
                convergenceConfig: convergenceConfig
            )
            transientAnalysis.executionBudget = executionBudget
            transientAnalysis.resultStorage = resultStorage
            let transientResult = try await transientAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )
            try Self.checkCancellation(cancellation)

            let scratchBytes = try TransientExecutionBudget.add(256,
                TransientExecutionBudget.multiply(transientResult.timePoints.count,
                    transientResult.solutionLowTrace == nil ? 32 : 64, "Fourier scratch capacity"),
                "Fourier scratch capacity")
            let scratch = try resultStorage?.reserveTemporaryBytes(UInt64(scratchBytes))
            defer { withExtendedLifetime(scratch) {} }

            // Phase 2: Extract the final period and compute Fourier coefficients
            let variableMap = plan.topology.variableMap

            var allHarmonics: [String: [FourierResult.HarmonicComponent]] = [:]
            var allTHD: [String: Double] = [:]

            for output in outputs {
                try Self.checkCancellation(cancellation)
                guard let varIndex = variableMap[output.variable] else {
                    throw AnalysisError.internalError(
                        "Validated Fourier output \(output.name) disappeared from variable map"
                    )
                }
                let varName = output.name

                // Admit the complete per-output integration and result before creating its buffers.
                if let budget = executionBudget {
                    let components = componentCount
                    let integrationPasses = try TransientExecutionBudget.add(
                        TransientExecutionBudget.multiply(harmonicCount, 2, "Fourier integration passes"), 1, "Fourier integration passes")
                    let integrationWork = try TransientExecutionBudget.multiply(
                        TransientExecutionBudget.multiply(transientResult.timePoints.count, integrationPasses, "Fourier integration work"),
                        32, "Fourier scalar work")
                    try budget.chargeWork(TransientExecutionBudget.add(integrationWork,
                        TransientExecutionBudget.multiply(components, 32, "Fourier coefficient work"), "Fourier work"))
                    try budget.admitSavedScalars(TransientExecutionBudget.add(
                        TransientExecutionBudget.multiply(components, 5, "Fourier component scalars"), 1, "Fourier THD scalar"))
                }

                let components: [FourierResult.HarmonicComponent]
                if let lowTrace = transientResult.solutionLowTrace {
                    let pairedPassWork = try TransientExecutionBudget.add(128,
                        TransientExecutionBudget.multiply(harmonicCount, 512, "paired Fourier harmonic work"),
                        "paired Fourier pass work")
                    try executionBudget?.chargeWork(TransientExecutionBudget.multiply(
                        transientResult.timePoints.count, pairedPassWork, "paired Fourier extraction and integration work"))
                    let waveform = try extractPairedLastPeriod(timePoints: transientResult.timePoints,
                        high: transientResult.solutionTrace.column(variableIndex: varIndex),
                        low: lowTrace.column(variableIndex: varIndex), period: period,
                        checkCancellation: { try Self.checkCancellation(cancellation) })
                    guard waveform.count >= 2 else {
                        throw AnalysisError.invalidConfiguration("Insufficient paired data in the final Fourier period")
                    }
                    components = try computePairedHarmonics(waveform: waveform, period: period,
                        checkCancellation: { try Self.checkCancellation(cancellation) })
                } else {
                    let waveform = try Self.extractLastPeriod(
                        timePoints: transientResult.timePoints,
                        values: transientResult.solutionTrace.column(variableIndex: varIndex),
                        period: period, checkCancellation: { try Self.checkCancellation(cancellation) })
                    guard waveform.count >= 2 else {
                        throw AnalysisError.invalidConfiguration("Insufficient data points in the final Fourier period")
                    }
                    components = try computeHarmonics(waveform: waveform, period: period,
                        checkCancellation: { try Self.checkCancellation(cancellation) })
                }
                allHarmonics[varName] = components

                // Compute THD
                let fundamental = components.first(where: { $0.harmonic == 1 })?.magnitude ?? 0
                if fundamental > 1e-30 {
                    var sumSquared = 0.0
                    for comp in components where comp.harmonic >= 2 {
                        if comp.harmonic.isMultiple(of: 256) { try Self.checkCancellation(cancellation) }
                        sumSquared += comp.magnitude * comp.magnitude
                    }
                    allTHD[varName] = sqrt(sumSquared) / fundamental * 100.0
                } else {
                    allTHD[varName] = 0.0
                }
            }

            guard allHarmonics.values.allSatisfy({ $0.allSatisfy {
                $0.frequency.isFinite && $0.magnitude.isFinite && $0.phase.isFinite && $0.normalizedMagnitude.isFinite
            }}), allTHD.values.allSatisfy({ $0.isFinite }) else {
                throw AnalysisError.invalidConfiguration("Fourier integration produced nonfinite coefficients")
            }
            let result = FourierResult(
                fundamentalFrequency: fundamentalFrequency,
                harmonics: allHarmonics,
                thd: allTHD,
                transientResult: transientResult
            )
            try Self.checkCancellation(cancellation)
            try completionFinalizer?.finalizeCompletion()
            try Self.checkCancellation(cancellation)
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .fourier,
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

    /// Extracts the final period, interpolating its left boundary between samples.
    public static func extractLastPeriod<Values: Collection>(
        timePoints: [Double],
        values: Values,
        period: Double
    ) -> [(time: Double, value: Double)] where Values.Element == Double, Values.Index == Int {
        extractLastPeriod(timePoints: timePoints, values: values, period: period, checkCancellation: {})
    }

    private static func extractLastPeriod<Values: Collection>(
        timePoints: [Double],
        values: Values,
        period: Double,
        checkCancellation: () throws -> Void
    ) rethrows -> [(time: Double, value: Double)] where Values.Element == Double, Values.Index == Int {
        guard let lastTime = timePoints.last else { return [] }
        let periodStart = lastTime - period

        var result: [(time: Double, value: Double)] = []
        result.reserveCapacity(timePoints.count)
        for (i, t) in timePoints.enumerated() {
            if i.isMultiple(of: 256) { try checkCancellation() }
            if t >= periodStart {
                if result.isEmpty, t > periodStart, i > 0 {
                    let previousTime = timePoints[i - 1]
                    let fraction = (periodStart - previousTime) / (t - previousTime)
                    let value = (1.0 - fraction) * values[i - 1] + fraction * values[i]
                    result.append((time: periodStart, value: value))
                }
                result.append((time: t, value: values[i]))
            }
        }
        return result
    }

    /// Computes Fourier coefficients by analytically integrating each linear segment.
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
        computeHarmonics(waveform: waveform, period: period, checkCancellation: {})
    }

    private func computeHarmonics(
        waveform: [(time: Double, value: Double)],
        period: Double,
        checkCancellation: () throws -> Void
    ) rethrows -> [FourierResult.HarmonicComponent] {
        try checkCancellation()
        var components: [FourierResult.HarmonicComponent] = []
        components.reserveCapacity(harmonicCount + 1)

        // DC component (harmonic 0)
        let dc = try trapezoidalIntegrate(waveform: waveform, checkCancellation: checkCancellation) { _, value in value } / period
        var fundamentalMagnitude = 0.0

        for k in 0...harmonicCount {
            try checkCancellation()
            let freq = Double(k) * fundamentalFrequency
            let omega = 2.0 * .pi * Double(k) * fundamentalFrequency

            let ak: Double
            let bk: Double

            if k == 0 {
                ak = dc
                bk = 0
            } else {
                let integrals = try integrateHarmonic(waveform: waveform, harmonic: k, omega: omega,
                    checkCancellation: checkCancellation)
                ak = (2.0 / period) * integrals.cosine
                bk = (2.0 / period) * integrals.sine
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

    private func integrateHarmonic(
        waveform: [(time: Double, value: Double)],
        harmonic: Int,
        omega: Double,
        checkCancellation: () throws -> Void
    ) rethrows -> (cosine: Double, sine: Double) {
        guard waveform.count >= 2 else { return (0, 0) }
        var cosineIntegral = 0.0
        var sineIntegral = 0.0
        for i in 1..<waveform.count {
            if i.isMultiple(of: 256) { try checkCancellation() }
            let left = waveform[i - 1]
            let right = waveform[i]
            let weights = harmonicWeights(leftTime: left.time, rightTime: right.time, harmonic: harmonic, omega: omega)
            let duration = weights.duration, sinc = weights.sinc, linearWeight = weights.linearWeight
            let cosine = weights.cosine, sine = weights.sine
            let average = 0.5 * left.value + 0.5 * right.value
            let halfDifference = 0.5 * right.value - 0.5 * left.value
            cosineIntegral += duration * (average * sinc * cosine - halfDifference * linearWeight * sine)
            sineIntegral += duration * (average * sinc * sine + halfDifference * linearWeight * cosine)
        }
        return (cosineIntegral, sineIntegral)
    }

    private func harmonicWeights(leftTime: Double, rightTime: Double, harmonic: Int, omega: Double)
        -> (duration: Double, sinc: Double, linearWeight: Double, cosine: Double, sine: Double) {
        let duration = rightTime - leftTime
        let halfAngle = 0.5 * omega * duration
        // Reduce the exact product in cycles before forming an angle or an unrepresentable midpoint.
        let cycles = fundamentalFrequency * leftTime
        let cycleError = (-cycles).addingProduct(fundamentalFrequency, leftTime)
        let reducedCycles = (cycles.remainder(dividingBy: 1.0) + cycleError.remainder(dividingBy: 1.0))
            .remainder(dividingBy: 1.0)
        let midpointAngle = 2.0 * .pi * (Double(harmonic) * reducedCycles).remainder(dividingBy: 1.0) + halfAngle
        let sinc: Double
        let linearWeight: Double
        if abs(halfAngle) < 1e-3 {
            // Series avoid cancellation in (sin(h) - h*cos(h))/h^2 near zero.
            let squared = halfAngle * halfAngle
            sinc = 1.0 - squared / 6.0 + squared * squared / 120.0
            linearWeight = halfAngle * (1.0 / 3.0 - squared / 30.0 + squared * squared / 840.0)
        } else {
            let sineHalfAngle = sin(halfAngle)
            sinc = sineHalfAngle / halfAngle
            linearWeight = (sineHalfAngle - halfAngle * cos(halfAngle)) / (halfAngle * halfAngle)
        }
        return (duration, sinc, linearWeight, cos(midpointAngle), sin(midpointAngle))
    }

    func extractPairedLastPeriod<High: RandomAccessCollection, Low: RandomAccessCollection>(
        timePoints: [Double], high: High, low: Low, period: Double,
        checkCancellation: () throws -> Void
    ) throws -> [(time: Double, value: CompensatedValue)] where High.Element == Double, Low.Element == Double {
        guard high.count == timePoints.count, low.count == timePoints.count, let end = timePoints.last else {
            throw AnalysisError.invalidConfiguration("Paired Fourier trace shape is invalid")
        }
        let start = end - period
        var result: [(time: Double, value: CompensatedValue)] = []
        result.reserveCapacity(timePoints.count)
        for index in timePoints.indices {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let time = timePoints[index]
            if time >= start {
                let highIndex = high.index(high.startIndex, offsetBy: index)
                let lowIndex = low.index(low.startIndex, offsetBy: index)
                let value = try CompensatedValue(high: high[highIndex], low: low[lowIndex])
                if result.isEmpty, time > start, index > 0 {
                    let previous = try CompensatedValue(high: high[high.index(before: highIndex)],
                        low: low[low.index(before: lowIndex)])
                    let fraction = (start - timePoints[index - 1]) / (time - timePoints[index - 1])
                    let boundary = try previous.adding(value.subtracting(previous)
                        .multiplied(by: CompensatedValue(high: fraction)))
                    result.append((start, boundary))
                }
                result.append((time, value))
            }
        }
        return result
    }

    func computePairedHarmonics(waveform: [(time: Double, value: CompensatedValue)], period: Double,
                               checkCancellation: () throws -> Void = {}) throws -> [FourierResult.HarmonicComponent] {
        guard let reference = waveform.first?.value, waveform.count >= 2 else { return [] }
        var centered: [(time: Double, value: CompensatedValue)] = []
        centered.reserveCapacity(waveform.count)
        for sample in waveform {
            try checkCancellation()
            centered.append((sample.time, try sample.value.subtracting(reference)))
        }
        let half = try CompensatedValue(high: 0.5)
        var area = CompensatedValue.zero
        for index in 1..<centered.count {
            try checkCancellation()
            let duration = try CompensatedValue(high: centered[index].time - centered[index - 1].time)
            area = try area.adding(centered[index - 1].value.adding(centered[index].value)
                .multiplied(by: half).multiplied(by: duration))
        }
        let dc = try reference.adding(area.divided(by: CompensatedValue(high: period)))
        var components: [FourierResult.HarmonicComponent] = []
        components.reserveCapacity(harmonicCount + 1)
        var fundamental = 0.0
        for harmonic in 0...harmonicCount {
            try checkCancellation()
            let frequency = Double(harmonic) * fundamentalFrequency
            var ak = dc.high + dc.low, bk = 0.0
            if harmonic > 0 {
                var cosine = CompensatedValue.zero, sine = CompensatedValue.zero
                for index in 1..<centered.count {
                    if index.isMultiple(of: 256) { try checkCancellation() }
                    let left = centered[index - 1], right = centered[index]
                    let weights = harmonicWeights(leftTime: left.time, rightTime: right.time,
                        harmonic: harmonic, omega: 2 * .pi * frequency)
                    let average = try left.value.adding(right.value).multiplied(by: half)
                    let difference = try right.value.subtracting(left.value).multiplied(by: half)
                    let c = try average.multiplied(by: CompensatedValue(high: weights.sinc * weights.cosine))
                        .subtracting(difference.multiplied(by: CompensatedValue(high: weights.linearWeight * weights.sine)))
                    let s = try average.multiplied(by: CompensatedValue(high: weights.sinc * weights.sine))
                        .adding(difference.multiplied(by: CompensatedValue(high: weights.linearWeight * weights.cosine)))
                    cosine = try cosine.adding(c.multiplied(by: CompensatedValue(high: weights.duration)))
                    sine = try sine.adding(s.multiplied(by: CompensatedValue(high: weights.duration)))
                }
                let scale = try CompensatedValue(high: 2 / period)
                let a = try cosine.multiplied(by: scale), b = try sine.multiplied(by: scale)
                ak = a.high + a.low; bk = b.high + b.low
            }
            let magnitude = harmonic == 0 ? abs(ak) : hypot(ak, bk)
            if harmonic == 1 { fundamental = magnitude }
            components.append(.init(harmonic: harmonic, frequency: frequency, magnitude: magnitude,
                phase: harmonic == 0 ? 0 : atan2(-bk, ak) * 180 / .pi,
                normalizedMagnitude: fundamental > 1e-30 ? magnitude / fundamental : 0))
        }
        return components
    }

    /// Computes the trapezoidal integral of f(t, v) over the waveform data.
    private func trapezoidalIntegrate(
        waveform: [(time: Double, value: Double)],
        checkCancellation: () throws -> Void,
        function: (Double, Double) -> Double
    ) rethrows -> Double {
        guard waveform.count >= 2 else { return 0 }

        var integral = 0.0
        for i in 1..<waveform.count {
            if i.isMultiple(of: 256) { try checkCancellation() }
            let t0 = waveform[i - 1].time
            let t1 = waveform[i].time
            let f0 = function(t0, waveform[i - 1].value)
            let f1 = function(t1, waveform[i].value)
            integral += 0.5 * (f0 + f1) * (t1 - t0)
        }
        return integral
    }

    private static func checkCancellation(_ cancellation: CancellationToken) throws {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
    }
}
