import CoreSpiceParsedIR
import CoreSpiceWaveform
import Foundation

/// Evaluates SPICE `.measure` controls against waveform data.
public struct SPICEMeasureEvaluator: Sendable {

    public init() {}

    /// Evaluates all measurements that match the waveform analysis kind.
    public func evaluate(
        measures: [MeasureSpec],
        waveform: WaveformData
    ) throws -> [SPICEMeasurementResult] {
        guard let matchingAnalysis = waveform.metadata.analysisType.outputAnalysisType else {
            return []
        }
        var results: [SPICEMeasurementResult] = []
        results.reserveCapacity(measures.count)

        for measure in measures where measure.analysisType == matchingAnalysis {
            let result = try evaluate(measure: measure, waveform: waveform)
            results.append(result)
        }

        return results
    }

    /// Evaluates a single measurement.
    public func evaluate(
        measure: MeasureSpec,
        waveform: WaveformData
    ) throws -> SPICEMeasurementResult {
        let value: Double
        let unit: String

        switch measure.measureType {
        case .find(let variable, let at):
            let series = try realSeries(for: variable, waveform: waveform)
            let x = try numericValue(at, field: "at", measure: measure.resultName)
            value = try interpolate(series: series, at: x)
            unit = series.unit.rawValue

        case .average(let variable, let from, let to):
            let series = try realSeries(for: variable, waveform: waveform)
            let slice = try slicedSeries(series, from: from, to: to, measureName: measure.resultName)
            value = try average(slice: slice, measureName: measure.resultName)
            unit = series.unit.rawValue

        case .rms(let variable, let from, let to):
            let series = try realSeries(for: variable, waveform: waveform)
            let slice = try slicedSeries(series, from: from, to: to, measureName: measure.resultName)
            value = try rms(slice: slice, measureName: measure.resultName)
            unit = series.unit.rawValue

        case .min(let variable, let from, let to):
            let series = try realSeries(for: variable, waveform: waveform)
            let slice = try slicedSeries(series, from: from, to: to, measureName: measure.resultName)
            value = try extrema(slice.values, measureName: measure.resultName).min
            unit = series.unit.rawValue

        case .max(let variable, let from, let to):
            let series = try realSeries(for: variable, waveform: waveform)
            let slice = try slicedSeries(series, from: from, to: to, measureName: measure.resultName)
            value = try extrema(slice.values, measureName: measure.resultName).max
            unit = series.unit.rawValue

        case .peakToPeak(let variable, let from, let to):
            let series = try realSeries(for: variable, waveform: waveform)
            let slice = try slicedSeries(series, from: from, to: to, measureName: measure.resultName)
            let extrema = try extrema(slice.values, measureName: measure.resultName)
            value = extrema.max - extrema.min
            unit = series.unit.rawValue

        case .integral(let variable, let from, let to):
            let series = try realSeries(for: variable, waveform: waveform)
            let slice = try slicedSeries(series, from: from, to: to, measureName: measure.resultName)
            value = try integral(slice: slice, measureName: measure.resultName)
            unit = "\(series.unit.rawValue)*\(waveform.sweepVariable.unit.rawValue)"

        case .riseTime(let variable, let lowThreshold, let highThreshold):
            let series = try realSeries(for: variable, waveform: waveform)
            value = try transitionTime(
                series: series,
                firstThreshold: lowThreshold,
                secondThreshold: highThreshold,
                direction: .rising,
                measureName: measure.resultName
            )
            unit = waveform.sweepVariable.unit.rawValue

        case .fallTime(let variable, let highThreshold, let lowThreshold):
            let series = try realSeries(for: variable, waveform: waveform)
            value = try transitionTime(
                series: series,
                firstThreshold: highThreshold,
                secondThreshold: lowThreshold,
                direction: .falling,
                measureName: measure.resultName
            )
            unit = waveform.sweepVariable.unit.rawValue

        case .delay(let variable1, let value1, let variable2, let value2):
            let firstSeries = try realSeries(for: variable1, waveform: waveform)
            let secondSeries = try realSeries(for: variable2, waveform: waveform)
            let firstThreshold = try numericValue(value1, field: "value1", measure: measure.resultName)
            let secondThreshold = try numericValue(value2, field: "value2", measure: measure.resultName)
            let firstCrossingTime = try firstCrossing(
                series: firstSeries,
                threshold: firstThreshold,
                direction: .any,
                after: nil,
                measureName: measure.resultName
            )
            let secondCrossing = try firstCrossing(
                series: secondSeries,
                threshold: secondThreshold,
                direction: .any,
                after: firstCrossingTime,
                measureName: measure.resultName
            )
            value = secondCrossing - firstCrossingTime
            unit = waveform.sweepVariable.unit.rawValue

        case .when:
            throw SPICEMeasurementError.unsupportedMeasure(
                name: measure.resultName,
                reason: "general expression-based WHEN measurements are not implemented"
            )
        case .unsupported(_, _, let reason):
            throw SPICEMeasurementError.unsupportedMeasure(
                name: measure.resultName,
                reason: reason
            )
        }

        return SPICEMeasurementResult(
            analysisType: measure.analysisType,
            name: measure.resultName,
            value: value,
            unit: unit
        )
    }

    private func realSeries(
        for variable: OutputVariable,
        waveform: WaveformData
    ) throws -> MeasuredSeries {
        switch variable {
        case .voltage(let node, let reference):
            let primary = try waveformSeries(named: "V(\(node))", waveform: waveform)
            guard let reference else {
                return primary
            }
            if Self.isGround(reference) {
                return primary
            }
            let referenceSeries = try waveformSeries(named: "V(\(reference))", waveform: waveform)
            try ensureCompatible(primary, referenceSeries)
            return MeasuredSeries(
                name: "V(\(node),\(reference))",
                unit: .volt,
                sweepValues: primary.sweepValues,
                values: zip(primary.values, referenceSeries.values).map { pair in pair.0 - pair.1 }
            )

        case .current(let device):
            return try waveformSeries(named: "I(\(device))", waveform: waveform)

        case .magnitude(let inner):
            return try transformedComplexSeries(
                inner,
                waveform: waveform,
                suffix: "_mag",
                unit: nil
            ) { real, imag in
                (real * real + imag * imag).squareRoot()
            }

        case .phase(let inner):
            return try transformedComplexSeries(
                inner,
                waveform: waveform,
                suffix: "_phase",
                unit: .degree
            ) { real, imag in
                atan2(imag, real) * 180.0 / .pi
            }

        case .real(let inner):
            return try transformedComplexSeries(
                inner,
                waveform: waveform,
                suffix: "_real",
                unit: .dimensionless
            ) { real, _ in
                real
            }

        case .imaginary(let inner):
            return try transformedComplexSeries(
                inner,
                waveform: waveform,
                suffix: "_imag",
                unit: .dimensionless
            ) { _, imag in
                imag
            }

        case .dB(let inner):
            return try transformedComplexSeries(
                inner,
                waveform: waveform,
                suffix: "_dB",
                unit: .decibel
            ) { real, imag in
                let magnitude = (real * real + imag * imag).squareRoot()
                return 20.0 * log10(max(magnitude, 1e-300))
            }

        case .power(let device):
            throw SPICEMeasurementError.unsupportedVariable(
                description: "P(\(device))",
                reason: "power waveforms are not generated by CoreSpice WaveformData"
            )

        case .expression:
            throw SPICEMeasurementError.unsupportedVariable(
                description: variable.descriptionForMeasurement,
                reason: "expression output variables are not implemented for measurements"
            )
        }
    }

    private func transformedComplexSeries(
        _ variable: OutputVariable,
        waveform: WaveformData,
        suffix: String,
        unit: SIUnit?,
        transform: (_ real: Double, _ imag: Double) -> Double
    ) throws -> MeasuredSeries {
        let baseName = variable.measurementVariableName
        guard let descriptor = waveform.variable(namedCaseInsensitive: baseName) else {
            throw SPICEMeasurementError.variableNotFound(baseName)
        }

        var values: [Double] = []
        values.reserveCapacity(waveform.pointCount)
        for point in 0..<waveform.pointCount {
            guard let complex = waveform.complexValue(variable: descriptor.index, point: point) else {
                throw SPICEMeasurementError.variableNotFound(baseName)
            }
            values.append(transform(complex.real, complex.imag))
        }

        return MeasuredSeries(
            name: baseName + suffix,
            unit: unit ?? descriptor.unit,
            sweepValues: waveform.sweepValues,
            values: values
        )
    }

    private func waveformSeries(
        named name: String,
        waveform: WaveformData
    ) throws -> MeasuredSeries {
        guard let descriptor = waveform.variable(namedCaseInsensitive: name) else {
            throw SPICEMeasurementError.variableNotFound(name)
        }
        guard let series = waveform.realWaveform(at: descriptor.index) else {
            throw SPICEMeasurementError.variableNotFound(name)
        }
        return MeasuredSeries(
            name: descriptor.name,
            unit: descriptor.unit,
            sweepValues: series.sweepValues,
            values: series.values
        )
    }

    private func slicedSeries(
        _ series: MeasuredSeries,
        from: ParsedParameterValue?,
        to: ParsedParameterValue?,
        measureName: String
    ) throws -> MeasuredSeries {
        guard !series.sweepValues.isEmpty, !series.values.isEmpty else {
            throw SPICEMeasurementError.emptyWaveform(measureName)
        }

        let start = try from.map { try numericValue($0, field: "from", measure: measureName) } ?? series.sweepValues[0]
        let end = try to.map { try numericValue($0, field: "to", measure: measureName) } ?? series.sweepValues[series.sweepValues.count - 1]
        guard start <= end else {
            throw SPICEMeasurementError.invalidRange(name: measureName, from: start, to: end)
        }
        guard start >= series.sweepValues[0], end <= series.sweepValues[series.sweepValues.count - 1] else {
            throw SPICEMeasurementError.rangeOutsideWaveform(name: measureName, from: start, to: end)
        }

        var xValues: [Double] = []
        var yValues: [Double] = []

        appendBoundaryPoint(start, series: series, xValues: &xValues, yValues: &yValues)
        for index in 0..<series.sweepValues.count {
            let x = series.sweepValues[index]
            if x > start && x < end {
                xValues.append(x)
                yValues.append(series.values[index])
            }
        }
        if end != start {
            appendBoundaryPoint(end, series: series, xValues: &xValues, yValues: &yValues)
        }

        return MeasuredSeries(
            name: series.name,
            unit: series.unit,
            sweepValues: xValues,
            values: yValues
        )
    }

    private func appendBoundaryPoint(
        _ x: Double,
        series: MeasuredSeries,
        xValues: inout [Double],
        yValues: inout [Double]
    ) {
        if let last = xValues.last, last == x {
            return
        }
        xValues.append(x)
        yValues.append(Self.interpolateUnchecked(series: series, at: x))
    }

    private func interpolate(series: MeasuredSeries, at target: Double) throws -> Double {
        guard !series.sweepValues.isEmpty else {
            throw SPICEMeasurementError.emptyWaveform(series.name)
        }
        guard target >= series.sweepValues[0],
              target <= series.sweepValues[series.sweepValues.count - 1] else {
            throw SPICEMeasurementError.pointOutsideWaveform(name: series.name, point: target)
        }
        return Self.interpolateUnchecked(series: series, at: target)
    }

    private static func interpolateUnchecked(series: MeasuredSeries, at target: Double) -> Double {
        if series.sweepValues.count == 1 {
            return series.values[0]
        }
        for index in 0..<(series.sweepValues.count - 1) {
            let x0 = series.sweepValues[index]
            let x1 = series.sweepValues[index + 1]
            if target == x0 {
                return series.values[index]
            }
            if target == x1 {
                return series.values[index + 1]
            }
            if target > x0 && target < x1 {
                let fraction = (target - x0) / (x1 - x0)
                return series.values[index] + fraction * (series.values[index + 1] - series.values[index])
            }
        }
        return series.values[series.values.count - 1]
    }

    private func integral(slice: MeasuredSeries, measureName: String) throws -> Double {
        guard slice.sweepValues.count >= 2 else {
            throw SPICEMeasurementError.insufficientPoints(name: measureName)
        }
        var sum = 0.0
        for index in 0..<(slice.sweepValues.count - 1) {
            let dx = slice.sweepValues[index + 1] - slice.sweepValues[index]
            let averageY = 0.5 * (slice.values[index] + slice.values[index + 1])
            sum += dx * averageY
        }
        return sum
    }

    private func average(slice: MeasuredSeries, measureName: String) throws -> Double {
        let width = try rangeWidth(slice, measureName: measureName)
        return try integral(slice: slice, measureName: measureName) / width
    }

    private func rms(slice: MeasuredSeries, measureName: String) throws -> Double {
        let width = try rangeWidth(slice, measureName: measureName)
        let squared = MeasuredSeries(
            name: slice.name,
            unit: slice.unit,
            sweepValues: slice.sweepValues,
            values: slice.values.map { $0 * $0 }
        )
        return (try integral(slice: squared, measureName: measureName) / width).squareRoot()
    }

    private func rangeWidth(_ slice: MeasuredSeries, measureName: String) throws -> Double {
        guard let first = slice.sweepValues.first, let last = slice.sweepValues.last, last > first else {
            throw SPICEMeasurementError.insufficientPoints(name: measureName)
        }
        return last - first
    }

    private func extrema(
        _ values: [Double],
        measureName: String
    ) throws -> (min: Double, max: Double) {
        guard let first = values.first else {
            throw SPICEMeasurementError.emptyWaveform(measureName)
        }
        var minimum = first
        var maximum = first
        for value in values.dropFirst() {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        return (minimum, maximum)
    }

    private func transitionTime(
        series: MeasuredSeries,
        firstThreshold: Double,
        secondThreshold: Double,
        direction: CrossingDirection,
        measureName: String
    ) throws -> Double {
        let first = try firstCrossing(
            series: series,
            threshold: firstThreshold,
            direction: direction,
            after: nil,
            measureName: measureName
        )
        let second = try firstCrossing(
            series: series,
            threshold: secondThreshold,
            direction: direction,
            after: first,
            measureName: measureName
        )
        return second - first
    }

    private func firstCrossing(
        series: MeasuredSeries,
        threshold: Double,
        direction: CrossingDirection,
        after: Double?,
        measureName: String
    ) throws -> Double {
        guard series.sweepValues.count >= 2 else {
            throw SPICEMeasurementError.insufficientPoints(name: measureName)
        }

        for index in 0..<(series.sweepValues.count - 1) {
            let x0 = series.sweepValues[index]
            let x1 = series.sweepValues[index + 1]
            if let after, x1 <= after {
                continue
            }

            let y0 = series.values[index]
            let y1 = series.values[index + 1]
            guard direction.matches(y0: y0, y1: y1, threshold: threshold) else {
                continue
            }
            let crossing = crossingTime(x0: x0, y0: y0, x1: x1, y1: y1, threshold: threshold)
            if let after, crossing <= after {
                continue
            }
            return crossing
        }

        throw SPICEMeasurementError.thresholdNotCrossed(
            name: measureName,
            variable: series.name,
            threshold: threshold
        )
    }

    private func crossingTime(
        x0: Double,
        y0: Double,
        x1: Double,
        y1: Double,
        threshold: Double
    ) -> Double {
        if y1 == y0 {
            return x0
        }
        let fraction = (threshold - y0) / (y1 - y0)
        return x0 + fraction * (x1 - x0)
    }

    private func numericValue(
        _ value: ParsedParameterValue,
        field: String,
        measure: String
    ) throws -> Double {
        switch value {
        case .numeric(let numeric):
            guard numeric.isFinite else {
                throw SPICEMeasurementError.invalidNumericValue(
                    measure: measure,
                    field: field,
                    value: numeric.description
                )
            }
            return numeric
        case .expression(.literal(let numeric)):
            guard numeric.isFinite else {
                throw SPICEMeasurementError.invalidNumericValue(
                    measure: measure,
                    field: field,
                    value: numeric.description
                )
            }
            return numeric
        case .boolean(let flag):
            return flag ? 1.0 : 0.0
        case .string(let text):
            throw SPICEMeasurementError.invalidNumericValue(
                measure: measure,
                field: field,
                value: text
            )
        case .expression(let expression):
            throw SPICEMeasurementError.unsupportedMeasure(
                name: measure,
                reason: "field '\(field)' uses unevaluated expression '\(expression)'"
            )
        }
    }

    private func ensureCompatible(_ lhs: MeasuredSeries, _ rhs: MeasuredSeries) throws {
        guard lhs.sweepValues == rhs.sweepValues, lhs.values.count == rhs.values.count else {
            throw SPICEMeasurementError.incompatibleWaveforms(lhs.name, rhs.name)
        }
    }

    fileprivate static func isGround(_ node: String) -> Bool {
        let normalized = node.lowercased()
        return normalized == "0" || normalized == "gnd" || normalized == "ground"
    }
}

private struct MeasuredSeries: Sendable {
    let name: String
    let unit: SIUnit
    let sweepValues: [Double]
    let values: [Double]
}

private enum CrossingDirection {
    case any
    case rising
    case falling

    func matches(y0: Double, y1: Double, threshold: Double) -> Bool {
        switch self {
        case .any:
            return (y0 <= threshold && y1 >= threshold)
                || (y0 >= threshold && y1 <= threshold)
        case .rising:
            return y0 <= threshold && y1 >= threshold && y1 != y0
        case .falling:
            return y0 >= threshold && y1 <= threshold && y1 != y0
        }
    }
}

private extension WaveformData {
    func variable(namedCaseInsensitive name: String) -> VariableDescriptor? {
        let lowered = name.lowercased()
        return variables.first { $0.name.lowercased() == lowered }
    }
}

private extension AnalysisKind {
    var outputAnalysisType: OutputAnalysisType? {
        switch self {
        case .operatingPoint:
            return .op
        case .dc:
            return .dc
        case .ac:
            return .ac
        case .transient:
            return .transient
        case .noise:
            return .noise
        case .transferFunction, .poleZero, .sensitivity, .fourier, .monteCarlo:
            return nil
        }
    }
}

private extension OutputVariable {
    var measurementVariableName: String {
        switch self {
        case .voltage(let node, let reference):
            if let reference, !SPICEMeasureEvaluator.isGround(reference) {
                return "V(\(node),\(reference))"
            }
            return "V(\(node))"
        case .current(let device):
            return "I(\(device))"
        case .power(let device):
            return "P(\(device))"
        case .magnitude(let inner), .phase(let inner), .real(let inner),
             .imaginary(let inner), .dB(let inner):
            return inner.measurementVariableName
        case .expression(let expression):
            return expression.description
        }
    }

    var descriptionForMeasurement: String {
        measurementVariableName
    }
}
