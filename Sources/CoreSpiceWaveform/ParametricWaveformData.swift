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

        public init(
            validatingIndex index: Int,
            parameters: [String: Double],
            waveform: WaveformData
        ) throws {
            try Self.validate(index: index, parameters: parameters)
            self.index = index
            self.parameters = parameters
            self.waveform = waveform
        }

        fileprivate static func validate(index: Int, parameters: [String: Double]) throws {
            guard index >= 0 else {
                throw ParametricWaveformValidationError.negativeRunIndex(index)
            }
            for (name, value) in parameters {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ParametricWaveformValidationError.emptyParameterName
                }
                guard value.isFinite else {
                    throw ParametricWaveformValidationError.nonFiniteParameterValue(
                        runIndex: index,
                        name: name,
                        value: value
                    )
                }
            }
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

    public init(
        validatingRuns runs: [Run],
        analysisType: AnalysisKind,
        title: String? = nil,
        parameterNames: [String]
    ) throws {
        try Self.validate(runs: runs, analysisType: analysisType, parameterNames: parameterNames)
        self.runs = runs
        self.analysisType = analysisType
        self.title = title
        self.parameterNames = parameterNames
    }

    private static func validate(
        runs: [Run],
        analysisType: AnalysisKind,
        parameterNames: [String]
    ) throws {
        guard !runs.isEmpty else {
            throw ParametricWaveformValidationError.emptyRuns
        }
        try validateParameterNames(parameterNames)

        var seenRunIndices: Set<Int> = []
        for run in runs {
            try Run.validate(index: run.index, parameters: run.parameters)
            guard seenRunIndices.insert(run.index).inserted else {
                throw ParametricWaveformValidationError.duplicateRunIndex(run.index)
            }
            try validateParameters(run: run, parameterNames: parameterNames)
            try validateWaveformShape(run: run)
            guard run.waveform.metadata.analysisType == analysisType else {
                throw ParametricWaveformValidationError.analysisTypeMismatch(
                    runIndex: run.index,
                    expected: analysisType,
                    actual: run.waveform.metadata.analysisType
                )
            }
        }

        guard let reference = runs.first?.waveform else {
            throw ParametricWaveformValidationError.emptyRuns
        }
        for run in runs.dropFirst() {
            try validateComparableWaveform(
                run: run,
                reference: reference
            )
        }
    }

    private static func validateWaveformShape(run: Run) throws {
        guard run.waveform.sweepValues.count == run.waveform.pointCount else {
            throw ParametricWaveformValidationError.pointCountMismatch(
                runIndex: run.index,
                expected: run.waveform.pointCount,
                actual: run.waveform.sweepValues.count
            )
        }
        guard run.waveform.variables.count == run.waveform.variableCount else {
            throw ParametricWaveformValidationError.variableCountMismatch(
                runIndex: run.index,
                expected: run.waveform.variableCount,
                actual: run.waveform.variables.count
            )
        }
    }

    private static func validateParameterNames(_ parameterNames: [String]) throws {
        var seenNames: Set<String> = []
        for name in parameterNames {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParametricWaveformValidationError.emptyParameterName
            }
            guard seenNames.insert(name).inserted else {
                throw ParametricWaveformValidationError.duplicateParameterName(name)
            }
        }
    }

    private static func validateParameters(run: Run, parameterNames: [String]) throws {
        let expectedNames = Set(parameterNames)
        for name in parameterNames where run.parameters[name] == nil {
            throw ParametricWaveformValidationError.missingParameterName(
                runIndex: run.index,
                name: name
            )
        }
        for name in run.parameters.keys where !expectedNames.contains(name) {
            throw ParametricWaveformValidationError.unexpectedParameterName(
                runIndex: run.index,
                name: name
            )
        }
    }

    private static func validateComparableWaveform(run: Run, reference: WaveformData) throws {
        let waveform = run.waveform
        guard waveform.sweepVariable == reference.sweepVariable else {
            throw ParametricWaveformValidationError.sweepVariableMismatch(runIndex: run.index)
        }
        guard waveform.isComplex == reference.isComplex else {
            throw ParametricWaveformValidationError.waveformComplexityMismatch(
                runIndex: run.index,
                expected: reference.isComplex,
                actual: waveform.isComplex
            )
        }
        guard waveform.pointCount == reference.pointCount else {
            throw ParametricWaveformValidationError.pointCountMismatch(
                runIndex: run.index,
                expected: reference.pointCount,
                actual: waveform.pointCount
            )
        }
        guard waveform.variableCount == reference.variableCount else {
            throw ParametricWaveformValidationError.variableCountMismatch(
                runIndex: run.index,
                expected: reference.variableCount,
                actual: waveform.variableCount
            )
        }

        for point in 0..<reference.pointCount {
            let expected = reference.sweepValues[point]
            let actual = waveform.sweepValues[point]
            guard expected == actual else {
                throw ParametricWaveformValidationError.sweepValueMismatch(
                    runIndex: run.index,
                    point: point,
                    expected: expected,
                    actual: actual
                )
            }
        }

        for variable in 0..<reference.variables.count {
            let expected = reference.variables[variable]
            let actual = waveform.variables[variable]
            guard expected == actual else {
                throw ParametricWaveformValidationError.variableDescriptorMismatch(
                    runIndex: run.index,
                    variable: variable,
                    expected: expected.name,
                    actual: actual.name
                )
            }
        }
    }

    // MARK: - Statistical Analysis

    /// Computes statistics for a variable across all runs, returning typed failures.
    public func checkedStatistics(
        forVariable name: String
    ) throws -> WaveformStatistics {
        try Self.validate(runs: runs, analysisType: analysisType, parameterNames: parameterNames)

        guard let firstRun = runs.first,
              firstRun.waveform.variableIndex(named: name) != nil else {
            throw ParametricWaveformValidationError.variableUnavailable(name)
        }

        let pointCount = firstRun.waveform.pointCount
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
            guard let variableIndex = run.waveform.variableIndex(named: name) else {
                throw ParametricWaveformValidationError.variableUnavailable(name)
            }
            for i in 0..<pointCount {
                guard let v = run.waveform.realValue(variable: variableIndex, point: i) else {
                    throw ParametricWaveformValidationError.unreadableVariableValue(
                        runIndex: run.index,
                        variable: name,
                        sweepIndex: i
                    )
                }
                guard v.isFinite else {
                    throw ParametricWaveformValidationError.nonFiniteWaveformValue(
                        runIndex: run.index,
                        variable: name,
                        sweepIndex: i,
                        value: v
                    )
                }
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
            sweepValues: firstRun.waveform.sweepValues,
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

    /// Computes statistics for a variable at a sweep index, returning typed failures.
    public func checkedStatistics(
        forVariable name: String,
        atSweepIndex sweepIndex: Int
    ) throws -> PointStatistics {
        try Self.validate(runs: runs, analysisType: analysisType, parameterNames: parameterNames)
        guard let firstRun = runs.first,
              firstRun.waveform.variableIndex(named: name) != nil else {
            throw ParametricWaveformValidationError.variableUnavailable(name)
        }
        guard sweepIndex >= 0, sweepIndex < firstRun.waveform.pointCount else {
            throw ParametricWaveformValidationError.sweepIndexOutOfRange(
                index: sweepIndex,
                pointCount: firstRun.waveform.pointCount
            )
        }

        var values: [Double] = []

        for run in runs {
            guard let variableIndex = run.waveform.variableIndex(named: name) else {
                throw ParametricWaveformValidationError.variableUnavailable(name)
            }
            guard let value = run.waveform.realValue(variable: variableIndex, point: sweepIndex) else {
                throw ParametricWaveformValidationError.unreadableVariableValue(
                    runIndex: run.index,
                    variable: name,
                    sweepIndex: sweepIndex
                )
            }
            guard value.isFinite else {
                throw ParametricWaveformValidationError.nonFiniteWaveformValue(
                    runIndex: run.index,
                    variable: name,
                    sweepIndex: sweepIndex,
                    value: value
                )
            }
            values.append(value)
        }

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
        let min = sorted[0]
        let max = sorted[sorted.count - 1]

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

    /// Returns the run that produced the minimum value, returning typed failures.
    public func checkedRunWithMinimum(
        of variable: String,
        at sweepIndex: Int = 0
    ) throws -> Run {
        try runWithExtremum(of: variable, at: sweepIndex, prefersCandidate: <)
    }

    /// Returns the run that produced the maximum value, returning typed failures.
    public func checkedRunWithMaximum(
        of variable: String,
        at sweepIndex: Int = 0
    ) throws -> Run {
        try runWithExtremum(of: variable, at: sweepIndex, prefersCandidate: >)
    }

    private func runWithExtremum(
        of variable: String,
        at sweepIndex: Int,
        prefersCandidate: (Double, Double) -> Bool
    ) throws -> Run {
        try Self.validate(runs: runs, analysisType: analysisType, parameterNames: parameterNames)
        guard let firstRun = runs.first,
              firstRun.waveform.variableIndex(named: variable) != nil else {
            throw ParametricWaveformValidationError.variableUnavailable(variable)
        }
        guard sweepIndex >= 0, sweepIndex < firstRun.waveform.pointCount else {
            throw ParametricWaveformValidationError.sweepIndexOutOfRange(
                index: sweepIndex,
                pointCount: firstRun.waveform.pointCount
            )
        }

        var selectedRun: Run?
        var selectedValue: Double?
        for run in runs {
            guard let variableIndex = run.waveform.variableIndex(named: variable),
                  let value = run.waveform.realValue(variable: variableIndex, point: sweepIndex) else {
                throw ParametricWaveformValidationError.unreadableVariableValue(
                    runIndex: run.index,
                    variable: variable,
                    sweepIndex: sweepIndex
                )
            }
            guard value.isFinite else {
                throw ParametricWaveformValidationError.nonFiniteWaveformValue(
                    runIndex: run.index,
                    variable: variable,
                    sweepIndex: sweepIndex,
                    value: value
                )
            }

            if let current = selectedValue {
                if prefersCandidate(value, current) {
                    selectedRun = run
                    selectedValue = value
                }
            } else {
                selectedRun = run
                selectedValue = value
            }
        }

        guard let selectedRun else {
            throw ParametricWaveformValidationError.emptyRuns
        }
        return selectedRun
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
