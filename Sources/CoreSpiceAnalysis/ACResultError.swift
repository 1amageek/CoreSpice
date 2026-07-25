import CoreSpiceIR

public enum ACResultError: Error, Sendable, Equatable, CustomStringConvertible {
    case frequencySolutionCountMismatch(frequencies: Int, solutions: Int)
    case nonFiniteFrequency(index: Int, value: Double)
    case inconsistentSolutionSize(index: Int, expected: Int, actual: Int)
    case variableIndexOutOfBounds(variable: MNAVariable, index: Int, count: Int)
    case frequencyIndexOutOfBounds(index: Int, count: Int)
    case missingNodeVoltage(nodeID: Int)

    public var description: String {
        switch self {
        case .frequencySolutionCountMismatch(let frequencies, let solutions):
            return "AC result has \(frequencies) frequencies but \(solutions) solutions."
        case .nonFiniteFrequency(let index, let value):
            return "AC frequency \(index) must be finite; received \(value)."
        case .inconsistentSolutionSize(let index, let expected, let actual):
            return "AC solution \(index) has \(actual) values; expected \(expected)."
        case .variableIndexOutOfBounds(let variable, let index, let count):
            return "AC variable \(variable) maps to index \(index) outside \(count) values."
        case .frequencyIndexOutOfBounds(let index, let count):
            return "AC frequency index \(index) is outside \(count) points."
        case .missingNodeVoltage(let nodeID):
            return "AC result does not contain node-voltage variable \(nodeID)."
        }
    }
}
