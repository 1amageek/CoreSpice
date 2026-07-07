import Foundation

/// Errors raised while evaluating `.measure` directives.
public enum SPICEMeasurementError: Error, Equatable, LocalizedError {
    case variableNotFound(String)
    case emptyWaveform(String)
    case insufficientPoints(name: String)
    case pointOutsideWaveform(name: String, point: Double)
    case rangeOutsideWaveform(name: String, from: Double, to: Double)
    case invalidRange(name: String, from: Double, to: Double)
    case invalidNumericValue(measure: String, field: String, value: String)
    case nonFiniteResult(name: String, value: String, reason: String)
    case thresholdNotCrossed(name: String, variable: String, threshold: Double)
    case incompatibleWaveforms(String, String)
    case unsupportedVariable(description: String, reason: String)
    case unsupportedMeasure(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .variableNotFound(let name):
            return "measurement variable not found: \(name)"
        case .emptyWaveform(let name):
            return "measurement '\(name)' cannot run on an empty waveform"
        case .insufficientPoints(let name):
            return "measurement '\(name)' requires at least two waveform points"
        case .pointOutsideWaveform(let name, let point):
            return "measurement point \(point) is outside waveform '\(name)'"
        case .rangeOutsideWaveform(let name, let from, let to):
            return "measurement '\(name)' range [\(from), \(to)] is outside the waveform"
        case .invalidRange(let name, let from, let to):
            return "measurement '\(name)' has invalid range [\(from), \(to)]"
        case .invalidNumericValue(let measure, let field, let value):
            return "measurement '\(measure)' field '\(field)' is not numeric: \(value)"
        case .nonFiniteResult(let name, let value, let reason):
            return "measurement '\(name)' produced non-finite result '\(value)': \(reason)"
        case .thresholdNotCrossed(let name, let variable, let threshold):
            return "measurement '\(name)' did not find threshold \(threshold) on \(variable)"
        case .incompatibleWaveforms(let lhs, let rhs):
            return "measurement waveforms are incompatible: \(lhs) and \(rhs)"
        case .unsupportedVariable(let description, let reason):
            return "measurement variable '\(description)' is unsupported: \(reason)"
        case .unsupportedMeasure(let name, let reason):
            return "measurement '\(name)' is unsupported: \(reason)"
        }
    }
}
