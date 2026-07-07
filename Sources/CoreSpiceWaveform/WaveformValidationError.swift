/// A typed validation failure for waveform shapes and projections.
public enum WaveformValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case negativePointCount(Int)
    case negativeVariableCount(Int)
    case pointProjectionOutOfRange(index: Int, pointCount: Int)
    case variableProjectionOutOfRange(index: Int, variableCount: Int)
    case projectionPointShapeMismatch(projectionPointCount: Int, basePointCount: Int)
    case projectionVariableShapeMismatch(projectionVariableCount: Int, baseVariableCount: Int)
    case rowMajorSweepCountMismatch(expected: Int, actual: Int)
    case rowMajorVariableCountMismatch(expected: Int, actual: Int)
    case rowMajorValueCountMismatch(expected: Int, actual: Int)
    case rowMajorValueCountOverflow(pointCount: Int, variableCount: Int, actual: Int)
    case sampleDataSweepCountMismatch(expected: Int, actual: Int)
    case sampleDataVariableCountMismatch(point: Int, expected: Int, actual: Int)
    case metadataPointCountMismatch(expected: Int, actual: Int)
    case metadataVariableCountMismatch(expected: Int, actual: Int)
    case metadataComplexityMismatch(expected: Bool, actual: Bool)
    case variableLayoutWidthMismatch(expected: Int, actual: Int)
    case mnaVariableIndexOutOfRange(index: Int, variableCount: Int)
    case mnaVariableIndicesNotContiguous(missingIndex: Int)

    public var description: String {
        switch self {
        case .negativePointCount(let count):
            return "Waveform point count must not be negative: \(count)."
        case .negativeVariableCount(let count):
            return "Waveform variable count must not be negative: \(count)."
        case .pointProjectionOutOfRange(let index, let pointCount):
            return "Waveform point projection index \(index) is outside 0..<\(pointCount)."
        case .variableProjectionOutOfRange(let index, let variableCount):
            return "Waveform variable projection index \(index) is outside 0..<\(variableCount)."
        case .projectionPointShapeMismatch(let projectionPointCount, let basePointCount):
            return "Waveform projection point count \(projectionPointCount) does not match base point count \(basePointCount)."
        case .projectionVariableShapeMismatch(let projectionVariableCount, let baseVariableCount):
            return "Waveform projection variable count \(projectionVariableCount) does not match base variable count \(baseVariableCount)."
        case .rowMajorSweepCountMismatch(let expected, let actual):
            return "Waveform sweep value count \(actual) does not match point count \(expected)."
        case .rowMajorVariableCountMismatch(let expected, let actual):
            return "Waveform variable descriptor count \(actual) does not match variable count \(expected)."
        case .rowMajorValueCountMismatch(let expected, let actual):
            return "Waveform row-major value count \(actual) does not match expected count \(expected)."
        case .rowMajorValueCountOverflow(let pointCount, let variableCount, let actual):
            return "Waveform row-major shape \(pointCount)x\(variableCount) overflows Int; actual value count is \(actual)."
        case .sampleDataSweepCountMismatch(let expected, let actual):
            return "Waveform sweep value count \(actual) does not match sample point count \(expected)."
        case .sampleDataVariableCountMismatch(let point, let expected, let actual):
            return "Waveform sample row \(point) width \(actual) does not match expected variable count \(expected)."
        case .metadataPointCountMismatch(let expected, let actual):
            return "Waveform metadata point count \(actual) does not match expected point count \(expected)."
        case .metadataVariableCountMismatch(let expected, let actual):
            return "Waveform metadata variable count \(actual) does not match expected variable count \(expected)."
        case .metadataComplexityMismatch(let expected, let actual):
            return "Waveform metadata complexity \(actual) does not match expected complexity \(expected)."
        case .variableLayoutWidthMismatch(let expected, let actual):
            return "Waveform variable layout width \(actual) does not match expected width \(expected)."
        case .mnaVariableIndexOutOfRange(let index, let variableCount):
            return "MNA variable index \(index) is outside 0..<\(variableCount)."
        case .mnaVariableIndicesNotContiguous(let missingIndex):
            return "MNA variable indices are not contiguous; missing index \(missingIndex)."
        }
    }
}
