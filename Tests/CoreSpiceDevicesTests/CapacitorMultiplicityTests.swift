import CoreSpiceIR
import Foundation
import Synchronization
import Testing
@testable import CoreSpiceDevices

@Suite("Ideal capacitor multiplicity", .timeLimit(.minutes(1)))
struct CapacitorMultiplicityTests {
    @Test(arguments: [false, true])
    func parallelCapacitanceAndInitialVoltage(useCSR: Bool) throws {
        let p = Node(id: 1), n = Node(id: 2)
        let map: [MNAVariable: Int] = [.nodeVoltage(p): 0, .nodeVoltage(n): 1]
        var context = BindingContext(variableMap: map, matrixDimension: 2,
            stampIndexResolver: { useCSR ? $0 * 2 + $1 : nil })
        let bound = try CapacitorDescriptor().bind(instance: Instance(name: "C", typeName: "capacitor",
            nodes: [p, n], parameters: ["c": .real(0.5), "m": .real(3), "ic": .real(2)]), context: &context)
        #expect((bound as? any VoltageInitialConditionDevice)?.initialVoltage == 2)
        let real = Mutex([Double](repeating: 0, count: 4))
        let imaginary = Mutex([Double](repeating: 0, count: 4))
        let rhs = Mutex([Double](repeating: 0, count: 2))
        var ac = ComplexMatrixStamper(variableMap: map,
            stampMatrix: { r, c, x, y in
                real.withLock { $0[r * 2 + c] += x }; imaginary.withLock { $0[r * 2 + c] += y }
            }, stampRHS: { _, _, _ in })
        let state = SolutionState(variables: [5, 1], previousVariables: [3, 1], variableMap: map)
        try bound.stampAC(into: &ac, state: state, omega: 2)
        #expect(imaginary.withLock { $0 } == [3, -3, -3, 3])
        var transient = MatrixStamper(variableMap: map,
            stampMatrix: { r, c, v in real.withLock { $0[r * 2 + c] += v } },
            stampRHS: { r, v in rhs.withLock { $0[r] += v } },
            stampValue: { i, v in real.withLock { $0[i] += v } })
        let integration = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)
        try bound.stampTransient(into: &transient, state: state, integration: integration)
        #expect(real.withLock { $0 } == [6, -6, -6, 6])
        #expect(rhs.withLock { $0 } == [12, -12])
        let residual = Mutex([Double](repeating: 0, count: 2))
        let physical = try #require(bound as? any TransientPhysicalResidualContributing)
        try physical.accumulateTransientPhysicalResidual(state: state, integration: integration,
            add: { r, v in residual.withLock { $0[r] += v } })
        #expect(residual.withLock { $0 } == [12, -12])
    }

    @Test func trapezoidalHistoryUsesTotalChargeAndRejectsTrialMutation() throws {
        let p = Node(id: 1)
        let map: [MNAVariable: Int] = [.nodeVoltage(p): 0]
        var context = BindingContext(variableMap: map, matrixDimension: 1)
        let bound = try CapacitorDescriptor().bind(instance: Instance(name: "C", typeName: "capacitor",
            nodes: [p, .ground], parameters: ["c": .real(0.5), "m": .real(3)]), context: &context)
        let session = try #require(bound as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: SolutionState(variables: [2], variableMap: map))
        defer { session.endTransientSession() }
        let first = SolutionState(variables: [4], previousVariables: [2], variableMap: map)
        try session.commitTransientStep(state: first,
            integration: IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25))
        let integration = IntegrationState(method: .trapezoidal, timeStep: 0.25, currentTime: 0.5)
        let physical = try #require(bound as? any TransientPhysicalResidualContributing)
        for voltage in [9.0, 5.0, 5.0] {
            let result = Mutex(0.0)
            try physical.accumulateTransientPhysicalResidual(
                state: SolutionState(variables: [voltage], previousVariables: [4], variableMap: map),
                integration: integration, add: { _, value in result.withLock { $0 += value } })
            #expect(result.withLock { $0 } == 12 * (voltage - 4) - 12)
        }
    }

    @Test func strictAdmission() {
        let invalid: [[String: ParameterValue]] = [
            ["c": .real(.infinity)], ["c": .real(.nan)], ["c": .real(1), "ic": .string("2")],
            ["c": .real(1), "ic": .real(.infinity)], ["c": .real(1), "m": .real(0)],
            ["c": .real(1), "m": .real(-1)], ["c": .real(1), "m": .string("2")],
            ["c": .real(1), "m": .real(.nan)], ["c": .real(1), "m": .real(.infinity)],
            ["c": .real(Double.greatestFiniteMagnitude), "m": .real(2)],
            ["c": .real(Double.leastNonzeroMagnitude), "m": .real(0.25)],
            ["c": .real(1), "unknown": .real(1)],
        ]
        for parameters in invalid {
            var context = BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0], matrixDimension: 1)
            #expect(throws: DeviceBindingError.self) {
                try CapacitorDescriptor().bind(instance: Instance(name: "C", typeName: "capacitor",
                    nodes: [Node(id: 1), .ground], parameters: parameters), context: &context)
            }
        }
    }
}
