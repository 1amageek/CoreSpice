import Foundation

/// A collection of waveforms from a parametric (corner/Monte Carlo) sweep.
///
/// Parametric waveform data stores multiple simulation runs indexed
/// by their parameter settings, enabling PVT corner analysis and
/// Monte Carlo result aggregation.
public struct ParametricWaveformData: Sendable {

    /// A single run's results with its parameter configuration.
    public struct Run: Sendable {

        /// The index of this run.
        public let index: Int

        /// The parameter values for this run.
        public let parameters: [String: Double]

        /// The waveform data for this run.
        public let waveform: WaveformData

        public init(
            index: Int,
            parameters: [String: Double],
            waveform: WaveformData
        ) {
            self.index = index
            self.parameters = parameters
            self.waveform = waveform
        }
    }

    /// All simulation runs.
    public let runs: [Run]

    /// The analysis type (all runs should have the same type).
    public let analysisType: AnalysisKind

    /// The title of the parametric sweep.
    public let title: String?

    /// The parameter names being varied.
    public let parameterNames: [String]

    /// The number of runs.
    public var runCount: Int {
        runs.count
    }

    public init(
        runs: [Run],
        analysisType: AnalysisKind,
        title: String? = nil,
        parameterNames: [String]
    ) {
        self.runs = runs
        self.analysisType = analysisType
        self.title = title
        self.parameterNames = parameterNames
    }

    // MARK: - Statistical Analysis

    /// Computes statistics for a variable across all runs at each point.
    public func statistics(
        forVariable name: String
    ) -> WaveformStatistics? {
        guard let firstRun = runs.first,
              let firstWaveform = firstRun.waveform.realWaveform(named: name) else {
            return nil
        }

        let pointCount = firstWaveform.count
        var means = [Double](repeating: 0.0, count: pointCount)
        var mins = [Double](repeating: .infinity, count: pointCount)
        var maxs = [Double](repeating: -.infinity, count: pointCount)
        var variances = [Double](repeating: 0.0, count: pointCount)
        var medians = [Double](repeating: 0.0, count: pointCount)
        var percentile5s = [Double](repeating: 0.0, count: pointCount)
        var percentile95s = [Double](repeating: 0.0, count: pointCount)

        // Collect all values for each point
        var allValues = [[Double]](repeating: [], count: pointCount)

        for run in runs {
            guard let waveform = run.waveform.realWaveform(named: name) else {
                continue
            }
            for i in 0..<min(pointCount, waveform.count) {
                let v = waveform[i]
                allValues[i].append(v)
                means[i] += v
                mins[i] = min(mins[i], v)
                maxs[i] = max(maxs[i], v)
            }
        }

        // Compute means using actual count per point (not total runs)
        for i in 0..<pointCount {
            let count = allValues[i].count
            if count > 0 {
                means[i] /= Double(count)
            }
        }

        // Compute standard deviations, variances, medians, and percentiles
        var stdDevs = [Double](repeating: 0.0, count: pointCount)
        for i in 0..<pointCount {
            let count = allValues[i].count
            guard count > 0 else { continue }

            // Variance and standard deviation
            if count > 1 {
                var sumSq = 0.0
                for v in allValues[i] {
                    sumSq += (v - means[i]) * (v - means[i])
                }
                // Use sample variance (Bessel's correction)
                variances[i] = sumSq / Double(count - 1)
                stdDevs[i] = variances[i].squareRoot()
            }

            // Sort for percentiles
            let sorted = allValues[i].sorted()

            // Median
            medians[i] = Self.percentile(sorted, p: 0.5)

            // Percentiles
            percentile5s[i] = Self.percentile(sorted, p: 0.05)
            percentile95s[i] = Self.percentile(sorted, p: 0.95)
        }

        return WaveformStatistics(
            variableName: name,
            sweepValues: firstWaveform.sweepValues,
            mean: means,
            minimum: mins,
            maximum: maxs,
            standardDeviation: stdDevs,
            variance: variances,
            median: medians,
            percentile5: percentile5s,
            percentile95: percentile95s,
            runCount: runs.count
        )
    }

    /// Computes statistics for a variable at a specific sweep index.
    public func statistics(
        forVariable name: String,
        atSweepIndex sweepIndex: Int
    ) -> PointStatistics? {
        var values: [Double] = []

        for run in runs {
            guard let waveform = run.waveform.realWaveform(named: name),
                  sweepIndex < waveform.count else {
                continue
            }
            values.append(waveform[sweepIndex])
        }

        guard !values.isEmpty else { return nil }

        let n = Double(values.count)
        let mean = values.reduce(0, +) / n

        // Variance and standard deviation (sample)
        var variance = 0.0
        if values.count > 1 {
            let sumSq = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            variance = sumSq / (n - 1)
        }
        let stddev = variance.squareRoot()

        // Sort for percentiles
        let sorted = values.sorted()
        let min = sorted.first!
        let max = sorted.last!

        return PointStatistics(
            mean: mean,
            standardDeviation: stddev,
            variance: variance,
            minimum: min,
            maximum: max,
            median: Self.percentile(sorted, p: 0.5),
            percentile5: Self.percentile(sorted, p: 0.05),
            percentile95: Self.percentile(sorted, p: 0.95),
            sampleCount: values.count
        )
    }

    /// Computes a percentile from a sorted array using linear interpolation.
    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }

        let n = Double(sorted.count)
        let index = (n - 1) * p
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        let fraction = index - Double(lower)

        if lower == upper || upper >= sorted.count {
            return sorted[Swift.min(lower, sorted.count - 1)]
        }
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// Returns the run that produced the minimum value of a variable.
    public func runWithMinimum(
        of variable: String,
        at sweepIndex: Int = 0
    ) -> Run? {
        runs.min { a, b in
            guard let wa = a.waveform.realWaveform(named: variable),
                  let wb = b.waveform.realWaveform(named: variable),
                  sweepIndex < wa.count, sweepIndex < wb.count else {
                return false
            }
            return wa[sweepIndex] < wb[sweepIndex]
        }
    }

    /// Returns the run that produced the maximum value of a variable.
    public func runWithMaximum(
        of variable: String,
        at sweepIndex: Int = 0
    ) -> Run? {
        runs.max { a, b in
            guard let wa = a.waveform.realWaveform(named: variable),
                  let wb = b.waveform.realWaveform(named: variable),
                  sweepIndex < wa.count, sweepIndex < wb.count else {
                return false
            }
            return wa[sweepIndex] < wb[sweepIndex]
        }
    }
}

/// Statistical summary of a waveform across parametric runs.
public struct WaveformStatistics: Sendable {

    /// The variable name.
    public let variableName: String

    /// The sweep values (x-axis).
    public let sweepValues: [Double]

    /// Mean value at each sweep point.
    public let mean: [Double]

    /// Minimum value at each sweep point.
    public let minimum: [Double]

    /// Maximum value at each sweep point.
    public let maximum: [Double]

    /// Standard deviation at each sweep point.
    public let standardDeviation: [Double]

    /// Variance at each sweep point.
    public let variance: [Double]

    /// Median value at each sweep point.
    public let median: [Double]

    /// 5th percentile at each sweep point.
    public let percentile5: [Double]

    /// 95th percentile at each sweep point.
    public let percentile95: [Double]

    /// The number of runs used in the statistics.
    public let runCount: Int

    /// The number of sweep points.
    public var pointCount: Int {
        sweepValues.count
    }

    /// Returns the ±3σ bounds.
    public var threeSigmaBounds: (lower: [Double], upper: [Double]) {
        var lower = [Double](repeating: 0, count: pointCount)
        var upper = [Double](repeating: 0, count: pointCount)
        for i in 0..<pointCount {
            lower[i] = mean[i] - 3.0 * standardDeviation[i]
            upper[i] = mean[i] + 3.0 * standardDeviation[i]
        }
        return (lower, upper)
    }

    /// Returns the ±1σ bounds.
    public var oneSigmaBounds: (lower: [Double], upper: [Double]) {
        var lower = [Double](repeating: 0, count: pointCount)
        var upper = [Double](repeating: 0, count: pointCount)
        for i in 0..<pointCount {
            lower[i] = mean[i] - standardDeviation[i]
            upper[i] = mean[i] + standardDeviation[i]
        }
        return (lower, upper)
    }

    /// Returns the 5th-95th percentile bounds.
    public var percentileBounds: (lower: [Double], upper: [Double]) {
        (percentile5, percentile95)
    }
}

/// Point-wise statistics for a single sweep index across runs.
public struct PointStatistics: Sendable {

    /// Mean value.
    public let mean: Double

    /// Standard deviation (sample).
    public let standardDeviation: Double

    /// Variance (sample).
    public let variance: Double

    /// Minimum value.
    public let minimum: Double

    /// Maximum value.
    public let maximum: Double

    /// Median value.
    public let median: Double

    /// 5th percentile.
    public let percentile5: Double

    /// 95th percentile.
    public let percentile95: Double

    /// Number of samples.
    public let sampleCount: Int
}
