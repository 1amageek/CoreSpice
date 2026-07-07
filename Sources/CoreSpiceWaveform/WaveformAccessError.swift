/// A typed waveform access failure for agent-facing and CLI-facing readers.
public enum WaveformAccessError: Error, Equatable, Sendable, CustomStringConvertible {
    case pointOutOfRange(point: Int, pointCount: Int)
    case variableOutOfRange(variable: Int, variableCount: Int)
    case unreadableSweepValue(point: Int)
    case unreadableRealValue(variable: Int, point: Int)
    case unreadableComplexValue(variable: Int, point: Int)

    public var description: String {
        switch self {
        case .pointOutOfRange(let point, let pointCount):
            return "Waveform point \(point) is outside 0..<\(pointCount)."
        case .variableOutOfRange(let variable, let variableCount):
            return "Waveform variable \(variable) is outside 0..<\(variableCount)."
        case .unreadableSweepValue(let point):
            return "Waveform sweep value at point \(point) is unreadable."
        case .unreadableRealValue(let variable, let point):
            return "Waveform real value at variable \(variable), point \(point) is unreadable."
        case .unreadableComplexValue(let variable, let point):
            return "Waveform complex value at variable \(variable), point \(point) is unreadable."
        }
    }
}
