import CoreSpice
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DirectDCPhysicalResidualTests {
    @Test func resistorUsesVoltageDifferenceBeforeMultiplicationAtLargeCommonMode() throws {
        let p = Node(id: 1), n = Node(id: 2)
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [p, n], parameters: ["r": .real(1000)])
        let map: [MNAVariable: Int] = [.nodeVoltage(p): 0, .nodeVoltage(n): 1]
        var context = BindingContext(variableMap: map, matrixDimension: 2)
        let device = try ResistorDescriptor().bind(instance: instance, context: &context)
        let physical = try #require(device as? any DCPhysicalResidualContributing)
        let x = [1e16, 1e16 - 2]
        var residual = [Double](repeating: 0, count: 2)
        try physical.accumulatePhysicalResidual(state: .init(variables: x, variableMap: map)) { residual[$0] += $1 }
        #expect(residual == [0.002, -0.002])
        #expect(residual[0] != 0.001 * x[0] - 0.001 * x[1])
        #expect(throws: (any Error).self) {
            try physical.accumulatePhysicalResidual(state: .init(variables: [1], variableMap: map)) { _, _ in }
        }
        #expect(throws: (any Error).self) {
            try physical.accumulatePhysicalResidual(state: .init(variables: [.infinity, 0], variableMap: map)) { _, _ in }
        }
    }

    @Test func sourcePhysicalResidualUsesActualDCValueAndBoundCurrent() throws {
        let p = Node(id: 1), branch = Branch(id: 0)
        let map: [MNAVariable: Int] = [.nodeVoltage(p): 0, .branchCurrent(branch): 1]
        var context = BindingContext(variableMap: map, matrixDimension: 2)
        let voltage = Instance(name: "V1", typeName: "vsource", nodes: [p, .ground],
            parameters: ["v1": .real(2), "v2": .real(100), "td": .real(0),
                         "tr": .real(1), "tf": .real(1), "pw": .real(1), "per": .real(4)], ownedBranches: [branch])
        let source = try VoltageSourceDescriptor().bind(instance: voltage, context: &context)
        let physical = try #require(source as? any DCPhysicalResidualContributing)
        var f = [Double](repeating: 0, count: 2)
        try physical.accumulatePhysicalResidual(state: .init(variables: [3, 0.02], variableMap: map)) { f[$0] += $1 }
        #expect(f == [0.02, 1])
        let current = Instance(name: "I1", typeName: "isource", nodes: [.ground, p], parameters: ["i": .real(0.005)])
        let other = try CurrentSourceDescriptor().bind(instance: current, context: &context)
        try #require(other as? any DCPhysicalResidualContributing)
            .accumulatePhysicalResidual(state: .init(variables: [3, 0.02], variableMap: map)) { f[$0] += $1 }
        #expect(abs(f[0] - 0.015) < 1e-15 && f[1] == 1)
        let currentPhysical = try #require(other as? any DCPhysicalResidualContributing)
        #expect(throws: (any Error).self) {
            try currentPhysical.accumulatePhysicalResidual(state: .init(variables: [.nan, 0.02], variableMap: map)) { _, _ in }
        }
    }
}
