import Testing
import CoreSpiceDevices
import CoreSpiceIR

@Suite(.timeLimit(.minutes(1)))
struct BoundCompensatedStateTests {
    private let node = Node(id: 1)
    private let other = Node(id: 2)
    private let branch = Branch(id: 0)

    @Test
    func typedNodeAndBranchReadsRetainBothComponents() throws {
        let state = SolutionState(variables: [0.5, 1],
            variableMap: [.nodeVoltage(node): 0, .branchCurrent(branch): 1],
            variableLowComponents: [0x1p-56, -0x1p-56])
        #expect(try state.checkedBoundCompensatedValue(at: 0, for: .nodeVoltage(node))
            == CompensatedValue(high: 0.5, low: 0x1p-56))
        #expect(try state.checkedBoundCompensatedValue(at: 1, for: .branchCurrent(branch))
            == CompensatedValue(high: 1, low: -0x1p-56))
        let ordinary = SolutionState(variables: [0.5], variableMap: [.nodeVoltage(node): 0])
        #expect(try ordinary.checkedBoundCompensatedValue(at: 0, for: .nodeVoltage(node))
            == CompensatedValue(high: 0.5))
    }

    @Test
    func wrongRowAndSameWidthSwapsFailEvenWhenValuesMatch() throws {
        let state = SolutionState(variables: [0.5, 0.5],
            variableMap: [.nodeVoltage(node): 0, .nodeVoltage(other): 1],
            variableLowComponents: [0x1p-56, 0x1p-56])
        #expect(throws: SolutionStateAccessError.variableIndexMismatch(expected: 1, actual: 0)) {
            _ = try state.checkedBoundCompensatedValue(at: 1, for: .nodeVoltage(node))
        }
        let swapped = SolutionState(variables: state.variables,
            variableMap: [.nodeVoltage(node): 1, .nodeVoltage(other): 0],
            variableLowComponents: state.variableLowComponents)
        #expect(throws: SolutionStateAccessError.variableIndexMismatch(expected: 0, actual: 1)) {
            _ = try swapped.checkedBoundCompensatedValue(at: 0, for: .nodeVoltage(node))
        }
    }

    @Test
    func branchCannotSubstituteForNodeAndMissingIdentitiesStayDistinct() throws {
        let state = SolutionState(variables: [1, 1],
            variableMap: [.nodeVoltage(node): 0, .branchCurrent(branch): 1])
        #expect(throws: SolutionStateAccessError.variableIndexMismatch(expected: 0, actual: 1)) {
            _ = try state.checkedBoundCompensatedValue(at: 0, for: .branchCurrent(branch))
        }
        #expect(throws: SolutionStateAccessError.missingNodeVoltage(nodeID: other.id)) {
            _ = try state.checkedBoundCompensatedValue(at: 1, for: .nodeVoltage(other))
        }
        #expect(throws: SolutionStateAccessError.missingBranchCurrent(branchID: 7)) {
            _ = try state.checkedBoundCompensatedValue(at: 0, for: .branchCurrent(Branch(id: 7)))
        }
    }

    @Test
    func groundZeroDoesNotAliasAnOrdinaryBoundRow() throws {
        let state = SolutionState(variables: [0.5], variableMap: [.nodeVoltage(node): 0],
            variableLowComponents: [0x1p-56])
        #expect(try state.checkedCompensatedVoltage(at: .ground) == .zero)
        #expect(throws: SolutionStateAccessError.missingNodeVoltage(nodeID: Node.ground.id)) {
            _ = try state.checkedBoundCompensatedValue(at: 0, for: .nodeVoltage(.ground))
        }
    }

    @Test
    func boundReadPreservesPairAndStorageValidation() throws {
        let variable = MNAVariable.nodeVoltage(node)
        let shortLow = SolutionState(variables: [0.5], variableMap: [variable: 0], variableLowComponents: [])
        #expect(throws: NumericalStateError.lowComponentCountMismatch(expected: 1, actual: 0)) {
            _ = try shortLow.checkedBoundCompensatedValue(at: 0, for: variable)
        }
        let overlap = SolutionState(variables: [0.5], variableMap: [variable: 0], variableLowComponents: [1])
        #expect(throws: NumericalStateError.nonNormalizedPair) {
            _ = try overlap.checkedBoundCompensatedValue(at: 0, for: variable)
        }
        let nonfinite = SolutionState(variables: [0.5], variableMap: [variable: 0], variableLowComponents: [.nan])
        #expect(throws: NumericalStateError.nonFiniteComponent) {
            _ = try nonfinite.checkedBoundCompensatedValue(at: 0, for: variable)
        }
        let badRow = SolutionState(variables: [0.5], variableMap: [variable: 1])
        #expect(throws: SolutionStateAccessError.valueIndexOutOfBounds(index: 1, count: 1)) {
            _ = try badRow.checkedBoundCompensatedValue(at: 1, for: variable)
        }
    }
}
