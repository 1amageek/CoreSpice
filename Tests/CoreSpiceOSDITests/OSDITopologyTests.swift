import CoreSpiceOSDITestSupport
import CoreSpiceIR
import CoreSpiceDevices
import OSDIContracts
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDITopologyTests {
    @Test func collapseGroundFlowAndThermalKeepCanonicalOwnership() throws {
        let topology = try OSDIPreparedTopology(nodes: [
            node(0, active: 0), node(1, active: 1), node(2, active: 1),
            node(3, active: nil), node(4, active: 2, units: "A", residual: "V", flow: true),
            node(5, active: 3, units: "K", residual: "W")
        ], activeUnknownCount: 4, stateCount: 0)
        var nextNode = 10, nextBranch = 7
        let projection = try OSDITopologyProjection(topology: topology,
            terminals: [Node(id: 1), .ground], nextNodeID: &nextNode, nextBranchID: &nextBranch)
        #expect(projection.activeVariables == [.nodeVoltage(Node(id: 1)), nil,
            .branchCurrent(Branch(id: 8)), .nodeVoltage(Node(id: 11))])
        #expect(projection.rawActive == [0, 1, 1, nil, 2, 3])
        #expect(projection.ownedNodes == [Node(id: 11)])
        #expect(projection.ownedBranches == [Branch(id: 8)])
        #expect(projection.activeKinds == [.electricalPotential, .electricalPotential, .electricalFlow, .thermalPotential])
        let context = BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0,
            .branchCurrent(Branch(id: 8)): 2, .nodeVoltage(Node(id: 11)): 1], matrixDimension: 3,
            stampIndexResolver: { row, col in row * 3 + col })
        let mapping = try OSDIBoundMapping(projection: projection, context: context)
        #expect(mapping.rawGlobal == [0, nil, nil, nil, 2, 1])
        #expect(mapping.csrIndices[0 * 6 + 4] == 2)
        #expect(mapping.csrIndices[4 * 6 + 5] == 7)
        #expect(mapping.csrIndices[2 * 6 + 4] == nil)
    }

    @Test func conflictingExternalCollapseAndUnknownNatureFail() throws {
        let collapsed = try OSDIPreparedTopology(nodes: [node(0, active: 0), node(1, active: 0)],
            activeUnknownCount: 1, stateCount: 0)
        var n = 2, b = 0
        do {
            _ = try OSDITopologyProjection(topology: collapsed, terminals: [Node(id: 1), Node(id: 2)],
                nextNodeID: &n, nextBranchID: &b)
            Issue.record("Distinct external nets were silently collapsed")
        } catch { guard case .collapsedExternalNets = error else { throw error } }
        let unknown = try OSDIPreparedTopology(nodes: [node(0, active: 0, units: "m", residual: "N")],
            activeUnknownCount: 1, stateCount: 0)
        do {
            _ = try OSDITopologyProjection(topology: unknown, terminals: [], nextNodeID: &n, nextBranchID: &b)
            Issue.record("Unsupported mechanical nature was admitted")
        } catch { guard case .unsupportedNature = error else { throw error } }
    }

    @Test func missingCSRAndCoordinateFailAtBinding() throws {
        let topology = try OSDIPreparedTopology(nodes: [node(0, active: 0)], activeUnknownCount: 1, stateCount: 0)
        var n = 1, b = 0
        let projection = try OSDITopologyProjection(topology: topology, terminals: [Node(id: 1)],
            nextNodeID: &n, nextBranchID: &b)
        for context in [BindingContext(variableMap: [:], matrixDimension: 1),
            BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0], matrixDimension: 1)] {
            do { _ = try OSDIBoundMapping(projection: projection, context: context); Issue.record("Invalid mapping admitted") }
            catch { guard case .invalidMatrixMapping = error else { throw error } }
        }
    }

    @Test func residualNoiseKeepsDescriptorNamesIndicesCollapseGroundAndAllAdmittedUnits() throws {
        let topology = try OSDIPreparedTopology(nodes: [
            node(0, active: 0), node(1, active: 1), node(2, active: 1), node(3, active: nil),
            node(4, active: 2, units: "A", residual: "V", flow: true),
            node(5, active: 3, units: "K", residual: "W")
        ], activeUnknownCount: 4, stateCount: 0)
        var n = 10, b = 7
        let projection = try OSDITopologyProjection(topology: topology, terminals: [Node(id: 1), .ground],
            nextNodeID: &n, nextBranchID: &b)
        let raw = try [
            OSDINoiseSourceInfo(index: 0, name: "same", kind: .white, positiveNodeIndex: 0, negativeNodeIndex: 1),
            OSDINoiseSourceInfo(index: 1, name: "same", kind: .flicker, positiveNodeIndex: 2, negativeNodeIndex: 3),
            OSDINoiseSourceInfo(index: 2, name: "voltage", kind: .white, positiveNodeIndex: 4, negativeNodeIndex: nil),
            OSDINoiseSourceInfo(index: 3, name: "power", kind: .table, positiveNodeIndex: 5, negativeNodeIndex: nil)
        ]
        let sources = try OSDINoiseProjection.project(sources: raw, topology: topology, projection: projection)
        #expect(sources.map(\.index) == [0, 1, 2, 3])
        #expect(sources.map(\.name) == ["same", "same", "voltage", "power"])
        #expect(sources.map(\.unit) == [.ampere, .ampere, .volt, .watt])
        #expect(sources[0].positive == .nodeVoltage(Node(id: 1)) && sources[0].negative == nil)
        #expect(sources[1].positive == nil && sources[1].negative == nil)
        #expect(sources[2].positive == .branchCurrent(Branch(id: 8)))
        #expect(sources[3].positive == .nodeVoltage(Node(id: 11)))
        let mixed = try OSDINoiseSourceInfo(index: 4, name: "mixed", kind: .white, positiveNodeIndex: 0, negativeNodeIndex: 5)
        do {
            _ = try OSDINoiseProjection.project(sources: [mixed], topology: topology, projection: projection)
            Issue.record("Mixed residual units admitted")
        } catch { guard case .invalidNoiseSources = error else { throw error } }
        do {
            _ = try OSDINoiseProjection.project(sources: [raw[0], raw[0]], topology: topology, projection: projection)
            Issue.record("Duplicate descriptor index admitted")
        } catch { guard case .invalidNoiseSources = error else { throw error } }
        #expect(try OSDIAdapterCapacity.noiseNames(raw) == 2 * (4 + 4 + 7 + 5))
    }

    private func node(_ index: Int, active: Int?, units: String = "V", residual: String = "A",
                      flow: Bool = false) throws -> OSDINodeInfo {
        try OSDINodeInfo(index: index, name: "n\(index)", units: units, residualUnits: residual,
            isFlow: flow, unknownNature: OSDINatureReference(kind: 0, index: 0),
            residualNature: OSDINatureReference(kind: 0, index: 0), activeUnknownIndex: active)
    }
}
