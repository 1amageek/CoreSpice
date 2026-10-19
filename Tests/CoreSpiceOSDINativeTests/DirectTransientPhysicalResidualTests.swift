@testable import CoreSpice
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DirectTransientPhysicalResidualTests {
    private final class AcceptanceCounter: TransientPhysicalResidualValidating {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }
        func validate(state: SolutionState, integration: IntegrationState) throws { count.withLock { $0 += 1 } }
    }

    @Test func newtonEquationEvaluationDoesNotInvokePriorAcceptanceConstraint() throws {
        let node = Node(id: 1), map: [MNAVariable: Int] = [.nodeVoltage(node): 0]
        var context = BindingContext(variableMap: map, matrixDimension: 1)
        let resistor = try ResistorDescriptor().bind(instance: .init(name: "R", typeName: "resistor", nodes: [node, .ground],
            parameters: ["r": .real(1000)]), context: &context)
        let contributor = try #require(resistor as? any TransientPhysicalResidualContributing)
        let prior = AcceptanceCounter()
        let row = try DCEquationRowPolicy(kind: .electricalPotential, variableAbsoluteTolerance: 1e-6, equationAbsoluteTolerance: 0.003)
        let validator = NativeOSDITransientValidator(contributors: [contributor], rows: [row],
            workspace: NativePhysicalResidualWorkspace(count: 1), cancellation: .init(), prior: prior)
        let state = SolutionState(variables: [2], previousVariables: [1], variableMap: map)
        let integration = IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 1)
        var residual = 0.0
        try validator.accumulateResidual(state: state, integration: integration) { _, value in residual += value }
        #expect(residual == 0.002)
        #expect(prior.calls == 0)
        try validator.validate(state: state, integration: integration)
        #expect(prior.calls == 1)
    }

    @Test func capacitorTrialsUseAcceptedCurrentWithoutCommittingRejectedCandidates() throws {
        let p = Node(id: 1), map: [MNAVariable: Int] = [.nodeVoltage(p): 0]
        var context = BindingContext(variableMap: map, matrixDimension: 1)
        let capacitor = try CapacitorDescriptor().bind(instance: .init(name: "C1", typeName: "capacitor", nodes: [p, .ground],
            parameters: ["c": .real(2)]), context: &context)
        let residual = try #require(capacitor as? any TransientPhysicalResidualContributing)
        let commit = try #require(capacitor as? any TransientStateCommittingDevice)
        let initial = SolutionState(variables: [2], previousVariables: [1], variableMap: map)
        let be = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
        var current = 0.0
        try residual.accumulateTransientPhysicalResidual(state: initial, integration: be) { _, value in current += value }
        #expect(current == 4)
        try commit.commitTransientStep(state: initial, integration: be)
        let tr = IntegrationState(method: .trapezoidal, timeStep: 0.25, currentTime: 0.75)
        current = 0
        try residual.accumulateTransientPhysicalResidual(state: .init(variables: [2.25], previousVariables: [2], variableMap: map), integration: tr) { _, value in current += value }
        #expect(current == 0)
        current = 0
        try residual.accumulateTransientPhysicalResidual(state: .init(variables: [2.5], previousVariables: [2], variableMap: map), integration: tr) { _, value in current += value }
        #expect(current == 4)
        #expect(throws: (any Error).self) {
            try residual.accumulateTransientPhysicalResidual(state: .init(variables: [2.5], previousVariables: [], variableMap: map), integration: tr) { _, _ in }
        }
        #expect(throws: (any Error).self) {
            try residual.accumulateTransientPhysicalResidual(state: .init(variables: [2.5], variableMap: map), integration: tr) { _, _ in }
        }
        #expect(throws: (any Error).self) {
            try residual.accumulateTransientPhysicalResidual(state: .init(variables: [2.5], previousVariables: [.nan], variableMap: map), integration: tr) { _, _ in }
        }
    }

    @Test func inductorUsesAdmittedBranchAndFullVoltageHistory() throws {
        let p = Node(id: 1), branch = Branch(id: 0)
        let map: [MNAVariable: Int] = [.nodeVoltage(p): 0, .branchCurrent(branch): 1]
        var context = BindingContext(variableMap: map, matrixDimension: 2)
        let device = try InductorDescriptor().bind(instance: .init(name: "L1", typeName: "inductor", nodes: [p, .ground],
            parameters: ["l": .real(3)], ownedBranches: [branch]), context: &context)
        let physical = try #require(device as? any TransientPhysicalResidualContributing)
        let state = SolutionState(variables: [10, 2], previousVariables: [4, 1], variableMap: map)
        var f = [Double](repeating: 0, count: 2)
        try physical.accumulateTransientPhysicalResidual(state: state,
            integration: .init(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)) { f[$0] += $1 }
        #expect(f == [2, 4])
        f = [0, 0]
        try physical.accumulateTransientPhysicalResidual(state: state,
            integration: .init(method: .trapezoidal, timeStep: 0.5, currentTime: 0.5)) { f[$0] += $1 }
        #expect(f == [2, 2])
    }

    @Test func sourceUsesPWLAtCandidateTimeAndAdmitsComplexACPhase() throws {
        let p = Node(id: 1), branch = Branch(id: 0)
        let map: [MNAVariable: Int] = [.nodeVoltage(p): 0, .branchCurrent(branch): 1]
        var context = BindingContext(variableMap: map, matrixDimension: 2)
        let device = try VoltageSourceDescriptor().bind(instance: .init(name: "V1", typeName: "vsource", nodes: [p, .ground],
            parameters: ["pwl": .realVector([0, 2, 1, 4]), "ac": .real(2), "acphase": .real(90)], ownedBranches: [branch]), context: &context)
        let state = SolutionState(variables: [3, 0.02], variableMap: map)
        var dc = [0.0, 0.0], tran = [0.0, 0.0]
        try #require(device as? any DCPhysicalResidualContributing).accumulatePhysicalResidual(state: state) { dc[$0] += $1 }
        try #require(device as? any TransientPhysicalResidualContributing).accumulateTransientPhysicalResidual(state: state,
            integration: .init(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)) { tran[$0] += $1 }
        #expect(dc == [0.02, 1])
        #expect(tran == [0.02, 0.5])
        var rhs = [ComplexPair](repeating: .init(), count: 2)
        var stamper = ComplexMatrixStamper(variableMap: map, stampMatrix: { _, _, _, _ in }, stampRHS: { row, real, imag in rhs[row] = .init(real: real, imag: imag) })
        try device.stampAC(into: &stamper, state: state, omega: 1)
        #expect(abs(rhs[1].real) < 1e-15)
        #expect(rhs[1].imag == 2)
    }
}
