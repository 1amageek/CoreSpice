import CoreSpiceOSDITestSupport
import CoreSpiceIR
import CoreSpiceDevices
import Foundation
import OSDIContracts
import Testing
@testable import CoreSpiceOSDI

@Suite("Actual OSDI continuous equation support", .timeLimit(.minutes(1)))
struct OSDIContinuousEquationStructureTests {
    private struct Entry: Equatable {
        let access: ContinuousEquationAccess
        let variable: MNAVariable
        let row: Int
    }
    private enum Refusal: Error, Equatable { case cancelled, workLimit }
    private func node(_ index: Int, active: Int?, units: String = "V", residual: String = "A", flow: Bool = false) throws -> OSDINodeInfo {
        try OSDINodeInfo(index: index, name: "n\(index)", units: units, residualUnits: residual, isFlow: flow,
            unknownNature: OSDINatureReference(kind: 0, index: 0), residualNature: OSDINatureReference(kind: 0, index: 0),
            activeUnknownIndex: active, hasReactiveResidual: false)
    }

    @Test func aliasesGroundBodyThermalAndInternalFlowsRetainCompleteSupport() throws {
        let topology = try OSDIPreparedTopology(nodes: [node(0, active: 0), node(1, active: 1),
            node(2, active: 0), node(3, active: nil), node(4, active: 2, units: "A", residual: "V", flow: true),
            node(5, active: 3, units: "K", residual: "W"), node(6, active: 4)], activeUnknownCount: 5, stateCount: 0)
        var nextNode = 10, nextBranch = 7
        let projection = try OSDITopologyProjection(topology: topology, terminals: [Node(id: 1), .ground],
            nextNodeID: &nextNode, nextBranchID: &nextBranch)
        let map: [MNAVariable: Int] = [.nodeVoltage(Node(id: 1)): 3, .branchCurrent(Branch(id: 8)): 0,
            .nodeVoltage(Node(id: 11)): 2, .nodeVoltage(Node(id: 12)): 1]
        let context = BindingContext(variableMap: map, matrixDimension: 4, stampIndexResolver: { $0 * 4 + $1 })
        let mapping = try OSDIBoundMapping(projection: projection, context: context)
        var entries: [Entry] = []
        try mapping.visitContinuousEquationStructure(device: "N1", checkpoint: {}) { access, variable, row in
            #expect(map[variable] == row)
            entries.append(Entry(access: access, variable: variable, row: row))
        }
        #expect(entries.filter { $0.access == .readCoordinate }.map(\.row) == [3, 0, 2, 1])
        for kind in [ContinuousEquationAccess.writeStaticResidual, .writeCharge] {
            // Reactive capability false is not used to omit any raw Q row.
            #expect(entries.filter { $0.access == kind }.map(\.row) == [3, 3, 0, 2, 1])
        }
        #expect(entries.contains { $0.variable == .branchCurrent(Branch(id: 8)) })
        #expect(entries.contains { $0.variable == .nodeVoltage(Node(id: 11)) })
        #expect(entries.contains { $0.variable == .nodeVoltage(Node(id: 12)) })
    }

    @Test func omittedGroundStillConsumesMandatoryCallerCheckpoints() throws {
        let topology = try OSDIPreparedTopology(nodes: [node(0, active: 0), node(1, active: 0), node(2, active: nil)],
            activeUnknownCount: 1, stateCount: 0)
        var nextNode = 0, nextBranch = 0
        let projection = try OSDITopologyProjection(topology: topology, terminals: [.ground],
            nextNodeID: &nextNode, nextBranchID: &nextBranch)
        let mapping = try OSDIBoundMapping(projection: projection, context: BindingContext(variableMap: [:], matrixDimension: 0))
        var work = 0
        #expect(throws: Refusal.workLimit) {
            try mapping.visitContinuousEquationStructure(device: "ground", checkpoint: {
                guard work < 2 else { throw Refusal.workLimit }; work += 1
            }) { _, _, _ in Issue.record("Ground emitted a global coordinate") }
        }
        #expect(work == 2)
        #expect(throws: Refusal.cancelled) {
            try mapping.visitContinuousEquationStructure(device: "ground", checkpoint: { throw Refusal.cancelled }) {
                _, _, _ in Issue.record("Cancelled traversal emitted support")
            }
        }
        var checkpoints = 0
        try mapping.visitContinuousEquationStructure(device: "ground", checkpoint: { checkpoints += 1 }) {
            _, _, _ in Issue.record("Ground emitted a global coordinate")
        }
        #expect(checkpoints == 5)
    }

    @Test func actualPreparedBindingExcludesForeignVoltageBranchWithoutDroppingLocalRows() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_ANALYSIS_MANIFEST"])
        let manifest = try JSONDecoder().decode(OSDIAnalysisManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let library = try #require(manifest.libraries.first { $0.descriptorName == "dynamic_flow_thermal" })
        let fixture = try OSDIAdapterFixture(library: library)
        let positive = Node(id: 1), selected = Branch(id: 77)
        let sourceInstance = Instance(name: "V1", typeName: "vsource", nodes: [positive, .ground],
            parameters: ["pwl": .realVector([0, 0, 1, 1])], ownedBranches: [selected])
        let modelInstance = try fixture.instance("N1", nodes: [positive, .ground])
        var prepared = try await fixture.prepareCircuit(CircuitIR(nodes: [positive, .ground], branches: [selected], instances: [modelInstance, sourceInstance]))
        do {
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            let voltage = try VoltageSourceDescriptor().bind(instance: sourceInstance, context: &context)
            let sourceFacts = try #require(voltage as? any IndependentVoltageSourceFactProviding)
            let fact = try sourceFacts.independentVoltageSourceFact()
            try fact.validateJoin(variableMap: topology.variableMap)
            guard let pending = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let actual = try pending.bind(context: &context)
            let support = try #require(actual as? any ContinuousEquationStructureProviding)
            var entries: [Entry] = []
            try support.visitContinuousEquationStructure(checkpoint: {}) { access, variable, row in
                #expect(topology.variableMap[variable] == row)
                #expect(row != fact.branchRow)
                entries.append(Entry(access: access, variable: variable, row: row))
            }
            for flow in actual.instance.ownedBranches {
                let row = try #require(topology.variableMap[.branchCurrent(flow)])
                #expect(flow != selected)
                #expect(entries.contains { $0.access == .readCoordinate && $0.row == row })
                #expect(entries.contains { $0.access == .writeCharge && $0.row == row })
            }
            for body in actual.instance.ownedNodes {
                let row = try #require(topology.variableMap[.nodeVoltage(body)])
                #expect(entries.contains { $0.access == .readCoordinate && $0.row == row })
                #expect(entries.contains { $0.access == .writeStaticResidual && $0.row == row })
            }
            #expect(!actual.instance.ownedBranches.isEmpty && !actual.instance.ownedNodes.isEmpty)
            #expect(throws: Refusal.cancelled) {
                try support.visitContinuousEquationStructure(checkpoint: {}) { _, _, _ in throw Refusal.cancelled }
            }
            var remaining = entries.count + 1
            let visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void = { _, _, _ in
                guard remaining > 0 else { throw Refusal.workLimit }; remaining -= 1
            }
            try support.visitContinuousEquationStructure(checkpoint: {}, visit)
            #expect(throws: Refusal.workLimit) { try support.visitContinuousEquationStructure(checkpoint: {}, visit) }
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }
}
