import CoreSpiceIR

public enum SolutionStateAccessError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingNodeVoltage(nodeID: Int)
    case missingBranchCurrent(branchID: Int)
    case variableIndexMismatch(expected: Int, actual: Int)
    case valueIndexOutOfBounds(index: Int, count: Int)

    public var description: String {
        switch self {
        case .missingNodeVoltage(let nodeID):
            return "Missing node-voltage variable for node \(nodeID)"
        case .missingBranchCurrent(let branchID):
            return "Missing branch-current variable for branch \(branchID)"
        case .variableIndexMismatch(let expected, let actual):
            return "Bound solution variable index \(expected) differs from state index \(actual)"
        case .valueIndexOutOfBounds(let index, let count):
            return "Solution variable index \(index) is out of bounds for \(count) values"
        }
    }
}
