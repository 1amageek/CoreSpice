import CoreSpiceIR

public enum DCResultValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case negativeIterationCount(Int)
    case nonFiniteVariable(index: Int, value: Double)
    case variableIndexOutOfBounds(variable: MNAVariable, index: Int, count: Int)
    case duplicateVariableIndex(Int)

    public var description: String {
        switch self {
        case .negativeIterationCount(let count):
            return "DC iteration count must be nonnegative; received \(count)."
        case .nonFiniteVariable(let index, let value):
            return "DC variable \(index) must be finite; received \(value)."
        case .variableIndexOutOfBounds(let variable, let index, let count):
            return "DC variable \(variable) maps to index \(index) outside \(count) values."
        case .duplicateVariableIndex(let index):
            return "Multiple DC variables map to solution index \(index)."
        }
    }
}
