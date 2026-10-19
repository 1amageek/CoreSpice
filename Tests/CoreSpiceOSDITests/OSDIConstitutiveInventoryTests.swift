import CoreSpiceIR
import CoreSpiceDevices
import OSDIContracts
import Testing
@testable import CoreSpiceOSDI

@Suite("Actual coordinate quotient inventory", .timeLimit(.minutes(1)))
struct OSDIConstitutiveInventoryTests {
    private func node(_ index: Int, active: Int?, thermal: Bool = false, flow: Bool = false) throws -> OSDINodeInfo {
        try OSDINodeInfo(index: index, name: "n\(index)", units: thermal ? "K" : flow ? "A" : "V",
            residualUnits: thermal ? "W" : flow ? "V" : "A", isFlow: flow,
            unknownNature: OSDINatureReference(kind: 0, index: 0), residualNature: OSDINatureReference(kind: 0, index: 0),
            activeUnknownIndex: active, hasReactiveResidual: false)
    }
    @Test func actualExternalEqualityGroundAliasesBodyThermalAndFlowRemainBound() throws {
        let topology = try OSDIPreparedTopology(nodes: [node(0, active: 0), node(1, active: 1), node(2, active: 2),
            node(3, active: 0), node(4, active: 3), node(5, active: 4, flow: true),
            node(6, active: 5, thermal: true), node(7, active: nil)], activeUnknownCount: 6, stateCount: 0)
        var nextNode = 1, nextBranch = 7
        let projection = try OSDITopologyProjection(topology: topology, terminals: [Node(id: 1), Node(id: 1), .ground],
            nextNodeID: &nextNode, nextBranchID: &nextBranch)
        let globals: [MNAVariable: Int] = [.nodeVoltage(Node(id: 1)): 1, .nodeVoltage(Node(id: 2)): 0,
            .branchCurrent(Branch(id: 8)): 2, .nodeVoltage(Node(id: 3)): 3]
        let mapping = try OSDIBoundMapping(projection: projection,
            context: BindingContext(variableMap: globals, matrixDimension: 4, stampIndexResolver: { $0 * 4 + $1 }))
        let control = OSDIConstitutiveTestControl()
        var inventory: OSDIConstitutiveInventory? = try OSDIConstitutiveInventory(instanceName: "Nactual",
            mapping: mapping, topology: topology, control: control)
        try #require(inventory).withView { view in
            let name = view.instanceName, dimension = view.matrixDimension
            let quotient = view.coordinateQuotient, raw = view.rawGlobal.count, active = view.activeGlobal.count
            #expect(name == "Nactual" && dimension == 4 && raw == 8 && active == 6)
            #expect(quotient.representatives == [0, 0, UInt32.max, 3, 4, 5])
            let expected: [Int?] = [1, 1, nil, 1, 0, 2, 3, nil]
            for i in expected.indices {
                let row = view.rawGlobal[i]
                #expect(row == expected[i])
            }
            let flow = view.activeVariables[4], thermal = view.activeVariables[5]
            #expect(flow == .branchCurrent(Branch(id: 8)) && thermal == .nodeVoltage(Node(id: 3)))
        }
        #expect(control.counters.live > 0)
        inventory = nil
        #expect(control.counters.live == 0)
    }
    @Test func storageAndWorkRefuseBeforeOwnedInventoryInitializationAndWrongTopologyRefuses() throws {
        let topology = try OSDIPreparedTopology(nodes: [node(0, active: 0)], activeUnknownCount: 1, stateCount: 0)
        var nextNode = 1, nextBranch = 0
        let projection = try OSDITopologyProjection(topology: topology, terminals: [Node(id: 1)], nextNodeID: &nextNode, nextBranchID: &nextBranch)
        let mapping = try OSDIBoundMapping(projection: projection,
            context: BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0], matrixDimension: 1, stampIndexResolver: { _, _ in 0 }))
        let storage = OSDIConstitutiveTestControl(storage: 1)
        #expect(throws: OSDIConstitutiveTestControl.Refusal.storage) {
            _ = try OSDIConstitutiveInventory(instanceName: "N", mapping: mapping, topology: topology, control: storage)
        }
        #expect(storage.counters.live == 0 && storage.counters.work == 0)
        let work = OSDIConstitutiveTestControl(work: 1)
        #expect(throws: OSDIConstitutiveTestControl.Refusal.work) {
            _ = try OSDIConstitutiveInventory(instanceName: "N", mapping: mapping, topology: topology, control: work)
        }
        #expect(work.counters.live == 0)
        let wrong = try OSDIPreparedTopology(nodes: [node(0, active: 0), node(1, active: 1)], activeUnknownCount: 2, stateCount: 0)
        do {
            _ = try OSDIConstitutiveInventory(instanceName: "N", mapping: mapping, topology: wrong, control: work)
            Issue.record("Mismatched topology initialized an inventory")
        } catch OSDIConstitutiveCaptureFailure.invalidBinding {}
    }
    @Test func distinctInternalFlowsCannotAcquireEqualityFromAReusedGlobalSlot() throws {
        let topology = try OSDIPreparedTopology(nodes: [node(0, active: 0), node(1, active: 1, flow: true), node(2, active: 2, flow: true)],
            activeUnknownCount: 3, stateCount: 0)
        var nextNode = 1, nextBranch = 0
        let projection = try OSDITopologyProjection(topology: topology, terminals: [Node(id: 1)], nextNodeID: &nextNode, nextBranchID: &nextBranch)
        let bad: [MNAVariable: Int] = [.nodeVoltage(Node(id: 1)): 0, .branchCurrent(Branch(id: 1)): 1, .branchCurrent(Branch(id: 2)): 1]
        do {
            _ = try OSDIBoundMapping(projection: projection, context: BindingContext(variableMap: bad,
                matrixDimension: 2, stampIndexResolver: { $0 * 2 + $1 }))
            Issue.record("Distinct internal flows shared a global coordinate")
        } catch OSDIAdapterFailure.invalidMatrixMapping {}
    }
    @Test func explicitSimulationFactValidationAdmitsTemporarySetBeforeWalking() throws {
        let facts = [try OSDISimulationParameter(name: "gmin", value: .real(0.0))]
        let refused = OSDIConstitutiveTestControl(storage: 1)
        #expect(throws: OSDIConstitutiveTestControl.Refusal.storage) {
            _ = try OSDIConstitutiveCapacity.simulationValidation(facts, control: refused)
        }
        #expect(refused.counters.live == 0 && refused.counters.work == 0)
        let control = OSDIConstitutiveTestControl()
        do {
            let lease = try OSDIConstitutiveCapacity.simulationValidation(facts, control: control)
            #expect(control.counters.live > 0 && control.counters.work > 0)
            withExtendedLifetime(lease) {}
        }
        #expect(control.counters.live == 0)
    }

}
