/// A typed validation failure for parametric waveform artifacts.
public enum ParametricWaveformValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyRuns
    case negativeRunIndex(Int)
    case duplicateRunIndex(Int)
    case emptyParameterName
    case duplicateParameterName(String)
    case missingParameterName(runIndex: Int, name: String)
    case unexpectedParameterName(runIndex: Int, name: String)
    case nonFiniteParameterValue(runIndex: Int, name: String, value: Double)
    case analysisTypeMismatch(runIndex: Int, expected: AnalysisKind, actual: AnalysisKind)
    case sweepVariableMismatch(runIndex: Int)
    case waveformComplexityMismatch(runIndex: Int, expected: Bool, actual: Bool)
    case pointCountMismatch(runIndex: Int, expected: Int, actual: Int)
    case variableCountMismatch(runIndex: Int, expected: Int, actual: Int)
    case sweepValueMismatch(runIndex: Int, point: Int, expected: Double, actual: Double)
    case variableDescriptorMismatch(runIndex: Int, variable: Int, expected: String, actual: String)
    case variableUnavailable(String)
    case sweepIndexOutOfRange(index: Int, pointCount: Int)
    case unreadableVariableValue(runIndex: Int, variable: String, sweepIndex: Int)
    case nonFiniteWaveformValue(runIndex: Int, variable: String, sweepIndex: Int, value: Double)

    public var description: String {
        switch self {
        case .emptyRuns:
            return "Parametric waveform data must contain at least one run."
        case .negativeRunIndex(let index):
            return "Parametric waveform run index must not be negative: \(index)."
        case .duplicateRunIndex(let index):
            return "Parametric waveform run index is duplicated: \(index)."
        case .emptyParameterName:
            return "Parametric waveform parameter names must not be empty."
        case .duplicateParameterName(let name):
            return "Parametric waveform parameter name is duplicated: \(name)."
        case .missingParameterName(let runIndex, let name):
            return "Parametric waveform run \(runIndex) is missing parameter '\(name)'."
        case .unexpectedParameterName(let runIndex, let name):
            return "Parametric waveform run \(runIndex) has unexpected parameter '\(name)'."
        case .nonFiniteParameterValue(let runIndex, let name, let value):
            return "Parametric waveform run \(runIndex) parameter '\(name)' is not finite: \(value)."
        case .analysisTypeMismatch(let runIndex, let expected, let actual):
            return "Parametric waveform run \(runIndex) analysis type \(actual.rawValue) does not match expected \(expected.rawValue)."
        case .sweepVariableMismatch(let runIndex):
            return "Parametric waveform run \(runIndex) sweep variable does not match the first run."
        case .waveformComplexityMismatch(let runIndex, let expected, let actual):
            return "Parametric waveform run \(runIndex) complexity \(actual) does not match expected \(expected)."
        case .pointCountMismatch(let runIndex, let expected, let actual):
            return "Parametric waveform run \(runIndex) point count \(actual) does not match expected \(expected)."
        case .variableCountMismatch(let runIndex, let expected, let actual):
            return "Parametric waveform run \(runIndex) variable count \(actual) does not match expected \(expected)."
        case .sweepValueMismatch(let runIndex, let point, let expected, let actual):
            return "Parametric waveform run \(runIndex) sweep value \(actual) at point \(point) does not match expected \(expected)."
        case .variableDescriptorMismatch(let runIndex, let variable, let expected, let actual):
            return "Parametric waveform run \(runIndex) variable \(variable) '\(actual)' does not match expected '\(expected)'."
        case .variableUnavailable(let name):
            return "Parametric waveform variable '\(name)' is unavailable."
        case .sweepIndexOutOfRange(let index, let pointCount):
            return "Parametric waveform sweep index \(index) is outside 0..<\(pointCount)."
        case .unreadableVariableValue(let runIndex, let variable, let sweepIndex):
            return "Parametric waveform run \(runIndex) variable '\(variable)' at sweep index \(sweepIndex) is unreadable."
        case .nonFiniteWaveformValue(let runIndex, let variable, let sweepIndex, let value):
            return "Parametric waveform run \(runIndex) variable '\(variable)' at sweep index \(sweepIndex) is not finite: \(value)."
        }
    }
}
