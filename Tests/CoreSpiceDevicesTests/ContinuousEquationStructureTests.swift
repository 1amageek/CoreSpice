import Testing
import CoreSpiceIR
@testable import CoreSpiceDevices

@Suite("Bound continuous equation structure", .timeLimit(.minutes(1)))
struct ContinuousEquationStructureTests {
    private let positive = Node(id: 1), negative = Node(id: 2), branch = Branch(id: 77)
    private var map: [MNAVariable: Int] {
        [.nodeVoltage(positive): 2, .nodeVoltage(negative): 0, .branchCurrent(branch): 1,
         .branchCurrent(Branch(id: 3)): 3]
    }
    private struct Entry: Equatable {
        let access: ContinuousEquationAccess
        let variable: MNAVariable
        let row: Int
    }
    private enum Refusal: Error, Equatable { case unproved, invalidJoin, selectedRead, selectedWrite, cancelled, workLimit }

    private func bind(_ type: String, _ parameters: [String: ParameterValue], ground: Bool = false) throws -> any BoundDevice {
        var context = BindingContext(variableMap: map, matrixDimension: 4)
        let instance = Instance(name: "D", typeName: type, nodes: [positive, ground ? .ground : negative],
            parameters: parameters, ownedBranches: type == "vsource" ? [branch] : [])
        switch type {
        case "resistor": return try ResistorDescriptor().bind(instance: instance, context: &context)
        case "capacitor": return try CapacitorDescriptor().bind(instance: instance, context: &context)
        default: return try VoltageSourceDescriptor().bind(instance: instance, context: &context)
        }
    }
    private func entries(_ device: any BoundDevice) throws -> [Entry] {
        guard let structure = device as? any ContinuousEquationStructureProviding else { throw Refusal.unproved }
        var result: [Entry] = []
        try structure.visitContinuousEquationStructure(checkpoint: {}) { access, variable, row in
            guard map[variable] == row else { throw Refusal.invalidJoin }
            result.append(.init(access: access, variable: variable, row: row))
        }
        return result
    }
    /// A test-only future-consumer obligation; protocol conformance is not a physical certificate.
    private func excludesSelectedSource(_ device: any BoundDevice) throws {
        for entry in try entries(device) where entry.row == map[.branchCurrent(branch)] {
            throw entry.access == .readCoordinate ? Refusal.selectedRead : Refusal.selectedWrite
        }
    }

    @Test func actualResistorAndCapacitorBindCompleteSeparateContinuousSupports() throws {
        for type in ["resistor", "capacitor"] {
            let device = try bind(type, [type == "resistor" ? "r" : "c": .real(3)])
            let support = try entries(device)
            let write: ContinuousEquationAccess = type == "resistor" ? .writeStaticResidual : .writeCharge
            #expect(support == [Entry(access: .readCoordinate, variable: .nodeVoltage(positive), row: 2),
                Entry(access: .readCoordinate, variable: .nodeVoltage(negative), row: 0),
                Entry(access: write, variable: .nodeVoltage(positive), row: 2),
                Entry(access: write, variable: .nodeVoltage(negative), row: 0)])
            try excludesSelectedSource(device)
            #expect(try entries(device) == support)
        }
    }

    @Test func groundIsOmittedButEqualNonGroundEndpointsAreNotSilentlyDeduplicated() throws {
        let ground = try bind("capacitor", ["c": .real(2)], ground: true)
        #expect(try entries(ground).map(\.row) == [2, 2])
        var context = BindingContext(variableMap: map, matrixDimension: 4)
        let same = try ResistorDescriptor().bind(instance: Instance(name: "same", typeName: "resistor",
            nodes: [positive, positive], parameters: ["r": .real(2)]), context: &context)
        #expect(try entries(same).map(\.row) == [2, 2, 2, 2])
    }

    @Test func actualSourceFactUsesClaimedBranchAndStoredValueLawWithExactAxisJoin() throws {
        let device = try bind("vsource", ["pwl": .realVector([0, 1, 1, 3])])
        let provider = try #require(device as? any IndependentVoltageSourceFactProviding)
        let fact = try provider.independentVoltageSourceFact()
        try fact.validateJoin(variableMap: map)
        #expect(fact.branch == branch && fact.branchRow == 1)
        #expect(fact.positiveNode == positive && fact.positiveRow == 2)
        #expect(fact.negativeNode == negative && fact.negativeRow == 0)
        #expect(fact.instance.name == device.instance.name)
        guard case .pwl(let points) = fact.waveform else { Issue.record("Actual bound waveform law was lost"); return }
        #expect(points.count == 2 && points[0].time == 0 && points[1].value == 3)
        #expect(fact.waveform.value(at: 0.5) == 2)
        let support = try entries(device)
        #expect(support.count == 6 && !support.contains { $0.access == .writeCharge })
        #expect(support.filter { $0.row == 1 }.map(\.access) == [.readCoordinate, .writeStaticResidual])
        #expect(throws: Refusal.selectedRead) { try excludesSelectedSource(device) }
        var wrong = map; wrong[.branchCurrent(branch)] = 3
        #expect(throws: ContinuousEquationStructureFailure.invalidBinding(device: "D")) { try fact.validateJoin(variableMap: wrong) }
        let physical = try #require(device as? any TransientPhysicalEquationDecomposing)
        var residual = [Double](repeating: 0, count: 4)
        try physical.accumulateTransientStaticResidual(state: SolutionState(variables: [1, 0.5, 3, 0], variableMap: map), time: 0.5) {
            residual[$0] += $1
        }
        #expect(residual == [-0.5, 0, 0.5, 0])
    }

    @Test func invalidBindingDoesNotTurnAnUnmappedNodeIntoGround() throws {
        var context = BindingContext(variableMap: [:], matrixDimension: 0)
        let device = try ResistorDescriptor().bind(instance: Instance(name: "missing", typeName: "resistor",
            nodes: [positive, .ground], parameters: ["r": .real(1)]), context: &context)
        let support = try #require(device as? any ContinuousEquationStructureProviding)
        #expect(throws: ContinuousEquationStructureFailure.invalidBinding(device: "missing")) {
            try support.visitContinuousEquationStructure(checkpoint: {}) { _, _, _ in Issue.record("Unmapped node was published") }
        }
    }

    @Test func currentFeedbackAndUnknownDeviceCannotMasqueradeAsIndependentSupport() throws {
        var context = BindingContext(variableMap: map, matrixDimension: 4, branchNames: [branch: "V1"])
        let feedback = try BranchReferencedCCCSDescriptor().bind(instance: Instance(name: "F1", typeName: "cccs_ref",
            nodes: [positive, .ground], parameters: ["f": .real(-1), "control_source": .string("V1")],
            referencedBranches: [branch]), context: &context)
        var coefficient = 0.0
        var stamp = MatrixStamper(variableMap: map, stampMatrix: { row, column, value in
            if row == 2 && column == 1 { coefficient += value }
        }, stampRHS: { _, _ in })
        try feedback.stampDC(into: &stamp, state: SolutionState(variables: [0, 0, 0, 0], variableMap: map))
        #expect(coefficient == -1)
        #expect(throws: Refusal.unproved) { try excludesSelectedSource(feedback) }
        let unknown = Unknown(instance: Instance(name: "V1", typeName: "vsource", nodes: [positive, .ground],
            parameters: ["v": .real(1)], ownedBranches: [branch]))
        let abstract: any BoundDevice = unknown
        #expect(!(abstract is any ContinuousEquationStructureProviding))
        #expect(!(abstract is any IndependentVoltageSourceFactProviding))
        #expect(throws: Refusal.unproved) { try excludesSelectedSource(unknown) }
    }

    @Test func visitorFailuresPropagateAndCallerWorkDoesNotResetAcrossQueries() throws {
        let device = try bind("capacitor", ["c": .real(2)])
        let support = try #require(device as? any ContinuousEquationStructureProviding)
        var work = 0
        let visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void = { _, _, _ in
            guard work < 5 else { throw Refusal.workLimit }; work += 1
        }
        try support.visitContinuousEquationStructure(checkpoint: {}, visit)
        #expect(work == 4)
        #expect(throws: Refusal.workLimit) { try support.visitContinuousEquationStructure(checkpoint: {}, visit) }
        #expect(work == 5)
        #expect(throws: Refusal.cancelled) { try support.visitContinuousEquationStructure(checkpoint: {}) { _, _, _ in throw Refusal.cancelled } }
        #expect(throws: Refusal.cancelled) {
            try support.visitContinuousEquationStructure(checkpoint: { throw Refusal.cancelled }) {
                _, _, _ in Issue.record("Cancelled checkpoint published support")
            }
        }
        #expect(try entries(device).count == 4)
    }

    private struct Unknown: BoundDevice {
        let instance: Instance
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {}
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {}
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {}
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
    }
}
