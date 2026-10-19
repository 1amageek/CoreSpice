import CoreSpiceOSDITestSupport
import Foundation
import Synchronization
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDIContracts
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDIAdapterExecutionTests {
    @Test func nonlinearFullSolutionStampAndRawPhysicalResidualAgree() async throws {
        let fixture = try OSDIAdapterFixture(descriptor: "cubic_dc")
        let input = try fixture.instance("N1", nodes: [Node(id: 1), Node(id: 2)])
        var prepared = try await fixture.prepare([input])
        do {
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let device = try owner.bind(context: &context)
            let x = [0.8, 0.2]
            let state = SolutionState(variables: x, variableMap: topology.variableMap)
            var matrix = [Double](repeating: 0, count: 4), rhs = [Double](repeating: 0, count: 2)
            var stamper = MatrixStamper(variableMap: topology.variableMap,
                stampMatrix: { matrix[$0 * 2 + $1] += $2 }, stampRHS: { rhs[$0] += $1 },
                stampValue: { matrix[$0] += $1 })
            try device.stampDC(into: &stamper, state: state)
            let voltage = x[0] - x[1]
            let current = 0.001 * voltage * voltage * voltage + 0.0002 * voltage + 0.0001
            let conductance = 0.003 * voltage * voltage + 0.0002
            #expect(abs(matrix[0] - conductance) < 1e-15)
            #expect(abs(matrix[1] + conductance) < 1e-15)
            #expect(abs(matrix[2] + conductance) < 1e-15)
            #expect(abs(matrix[3] - conductance) < 1e-15)
            #expect(abs(rhs[0] - (conductance * voltage - current)) < 1e-15)
            #expect(abs(rhs[1] + rhs[0]) < 1e-15)
            let physical = try #require(device as? any OSDIPhysicalResidualContributing)
            var residual = [Double](repeating: 0, count: 2)
            try physical.accumulatePhysicalResidual(state: state) { residual[$0] += $1 }
            #expect(abs(residual[0] - current) < 1e-15)
            #expect(abs(residual[1] + current) < 1e-15)
            for row in 0..<2 {
                #expect(abs(matrix[row * 2] * x[0] + matrix[row * 2 + 1] * x[1] - rhs[row] - residual[row]) < 1e-15)
            }
            try prepared.close()
            do { try device.stampDC(into: &stamper, state: state); Issue.record("Closed device executed") }
            catch { guard case OSDIAdapterFailure.closed = error else { throw error } }
        } catch {
            do { try prepared.close() } catch { Issue.record("Cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    @Test func collapseAndSeparateInstancesHavePrivateCoordinatesAndSummedStamps() async throws {
        let fixture = try OSDIAdapterFixture(descriptor: "collapsible_dc")
        let off = try fixture.instance("Noff", nodes: [Node(id: 1), Node(id: 2)],
            modelParameters: [OSDIParameterAssignment(name: "collapse", scope: .model, value: .integer(0))])
        let on = try fixture.instance("Non", nodes: [Node(id: 3), Node(id: 2)],
            modelParameters: [OSDIParameterAssignment(name: "collapse", scope: .model, value: .integer(1))])
        var prepared = try await fixture.prepare([off, on])
        do {
            #expect(prepared.circuit.instances[0].ownedNodes.count == 1)
            #expect(prepared.circuit.instances[1].ownedNodes.isEmpty)
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            guard let firstOwner = try prepared.takeDevice(at: 0),
                  let secondOwner = try prepared.takeDevice(at: 1) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let first = try firstOwner.bind(context: &context)
            let second = try secondOwner.bind(context: &context)
            var x = [Double](repeating: 0, count: topology.matrixSize)
            x[try #require(topology.variableMap[.nodeVoltage(Node(id: 1))])] = 1.7
            x[try #require(topology.variableMap[.nodeVoltage(Node(id: 2))])] = 0.2
            x[try #require(topology.variableMap[.nodeVoltage(Node(id: 3))])] = 0.6
            x[try #require(topology.variableMap[.nodeVoltage(prepared.circuit.instances[0].ownedNodes[0])])] = 0.7
            let state = SolutionState(variables: x, variableMap: topology.variableMap)
            var f = [Double](repeating: 0, count: x.count)
            for device in [first, second] {
                try #require(device as? any OSDIPhysicalResidualContributing).accumulatePhysicalResidual(state: state) { f[$0] += $1 }
            }
            #expect(abs(f[try #require(topology.variableMap[.nodeVoltage(Node(id: 1))])] - 0.001) < 1e-15)
            #expect(abs(f[try #require(topology.variableMap[.nodeVoltage(Node(id: 3))])] - 0.0004) < 1e-15)
            #expect(abs(f[try #require(topology.variableMap[.nodeVoltage(prepared.circuit.instances[0].ownedNodes[0])])]) < 1e-15)
            var matrix = [Double](repeating: 0, count: x.count * x.count)
            var rhs = [Double](repeating: 0, count: x.count)
            var stamp = MatrixStamper(variableMap: topology.variableMap, stampMatrix: { _, _, _ in },
                stampRHS: { rhs[$0] += $1 }, stampValue: { matrix[$0] += $1 })
            try first.stampDC(into: &stamp, state: state)
            try second.stampDC(into: &stamp, state: state)
            for row in x.indices {
                var residual = -rhs[row]
                for col in x.indices { residual += matrix[row * x.count + col] * x[col] }
                #expect(abs(residual - f[row]) < 1e-15)
            }
            try prepared.close()
        } catch { do { try prepared.close() } catch { Issue.record("Cleanup failed") }; throw error }
        try await fixture.close()
    }

    @Test func capacityIdentityAndStateRefusalsDoNotPoisonFreshPreparation() async throws {
        let fixture = try OSDIAdapterFixture(descriptor: "linear_dc")
        let normal = try fixture.instance("N1", nodes: [Node(id: 1), .ground])
        do {
            for (count, bytes) in [(0, UInt64(16_777_216)), (1, UInt64(1))] {
                do {
                    let unexpected = try await fixture.prepare([normal], maximumInstanceCount: count, maximumAdapterBytes: bytes)
                    try unexpected.close(); Issue.record("Capacity refusal was lost")
                } catch { guard case OSDIAdapterFailure.capacityExceeded = error else { throw error } }
            }
            let excessive = try fixture.instance("Nexcess", nodes: [Node(id: 1), .ground, Node(id: 2)])
            do {
                let unexpected = try await fixture.prepare([excessive])
                try unexpected.close(); Issue.record("More connections than descriptor terminals were admitted")
            } catch { guard case OSDIAdapterFailure.identityMismatch = error else { throw error } }
            let invalidBinding = try OSDIModelBinding(modelName: "wrong", artifact: fixture.reference,
                descriptorIndex: fixture.library.descriptorIndex, expectedDescriptorName: "wrong_descriptor", modelParameters: [])
            let invalid = try OSDIResolvedInstance(binding: invalidBinding, instanceParameters: [], previousState: [])
            do {
                let unexpected = try await fixture.prepare([Instance(name: "Nbad", typeName: "osdi", nodes: normal.nodes,
                    parameters: [:], osdi: .resolved(invalid))])
                try unexpected.close(); Issue.record("Wrong descriptor identity admitted")
            } catch { guard case OSDIAdapterFailure.identityMismatch = error else { throw error } }
            let badState = try OSDIResolvedInstance(binding: try #require(normal.osdi).resolved.binding,
                instanceParameters: [], previousState: [1])
            do {
                let unexpected = try await fixture.prepare([Instance(name: "Nstate", typeName: "osdi", nodes: normal.nodes,
                    parameters: [:], osdi: .resolved(badState))])
                try unexpected.close(); Issue.record("Wrong state dimension admitted")
            } catch {
                guard case OSDIAdapterFailure.integration(.stateDimensionMismatch) = error else { throw error }
            }
            let valid = try await fixture.prepare([normal])
            try valid.close()
        } catch {
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }
            throw error
        }
        try await fixture.close()
    }

    @Test func logicalPeakIncludesBindingTablesAndPrivateNamesStayBounded() async throws {
        let fixture = try OSDIAdapterFixture(descriptor: "collapsible_dc")
        let longName = String(repeating: "N", count: 65_536)
        let input = try fixture.instance(longName, nodes: [Node(id: 1), .ground],
            modelParameters: [OSDIParameterAssignment(name: "collapse", scope: .model, value: .integer(0))])
        let ir = CircuitIR(nodes: [.ground, Node(id: 1)], branches: [], instances: [input])
        do {
            let initial = try OSDIAdapterCapacity.initial(ir: ir)
            let formerNumericCharge = UInt64(3 * 3 * 16 + 3 * 128)
            let budget = initial + formerNumericCharge
            #expect(try OSDIAdapterCapacity.instance(nodeCount: 3, stateCount: 0) > formerNumericCharge)
            do {
                let unexpected = try await fixture.prepare([input], maximumAdapterBytes: budget)
                try unexpected.close(); Issue.record("Binding dictionary/storage peak escaped admission")
            } catch { guard case OSDIAdapterFailure.capacityExceeded = error else { throw error } }
            var reservedNodes = ir.nodes, reservedBranches = ir.branches, reservedInstances = ir.instances
            var reservedNodeNames = ir.nodeNames, reservedBranchNames = ir.branchNames
            reservedNodes.reserveCapacity(512); reservedBranches.reserveCapacity(512); reservedInstances.reserveCapacity(256)
            reservedNodeNames.reserveCapacity(256); reservedBranchNames.reserveCapacity(256)
            let reserved = CircuitIR(nodes: reservedNodes, branches: reservedBranches, instances: reservedInstances,
                nodeNames: reservedNodeNames, branchNames: reservedBranchNames)
            let ordinaryBudget = initial + (try OSDIAdapterCapacity.instance(nodeCount: 3, stateCount: 0))
            #expect(try OSDIAdapterCapacity.initial(ir: reserved) > ordinaryBudget)
            do {
                let unexpected = try await fixture.prepareCircuit(reserved, maximumAdapterBytes: ordinaryBudget)
                try unexpected.close(); Issue.record("Reserved original IR backing escaped COW admission")
            } catch { guard case OSDIAdapterFailure.capacityExceeded = error else { throw error } }
            let valid = try await fixture.prepare([input])
            for node in valid.circuit.instances[0].ownedNodes {
                let name = try #require(valid.circuit.nodeNames[node])
                #expect(name == "osdi:\(node.id)")
                #expect(name.utf8.count <= 32)
            }
            try valid.close()
            let collisionIR = CircuitIR(nodes: ir.nodes, branches: [], instances: [input],
                nodeNames: [Node(id: 1): "OSDI:2"])
            do {
                let unexpected = try await OSDICircuitPreparer().prepare(ir: collisionIR, operatingConditions: .nominal,
                    provider: fixture.provider,
                    loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 16_777_216),
                    evaluationLimits: OSDIEvaluationLimits(maximumWorkspaceBytes: 16_777_216, maximumDiagnosticCount: 64,
                        maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 16, maximumAdapterBytes: 16_777_216)
                try unexpected.close(); Issue.record("Bounded generated name collision was admitted")
            } catch { guard case OSDIAdapterFailure.invalidTopology = error else { throw error } }
        } catch { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }; throw error }
        try await fixture.close()
    }

    @Test func concurrentStampAndCloseFailBusyThenOwnerClosesAfterCheckoutReturns() async throws {
        let fixture = try OSDIAdapterFixture(descriptor: "linear_dc")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let device = try owner.bind(context: &context)
            let lifetime = prepared.lifetime
            let state = SolutionState(variables: [1], variableMap: topology.variableMap)
            let gate = Gate()
            try await withThrowingTaskGroup(of: Bool.self) { group in
                defer { gate.release.store(true, ordering: .releasing) }
                group.addTask {
                    var stamp = MatrixStamper(variableMap: topology.variableMap,
                        stampMatrix: { _, _, _ in }, stampRHS: { _, _ in }, stampValue: { _, _ in
                            if !gate.entered.exchange(true, ordering: .acquiringAndReleasing) {
                                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                                while !gate.release.load(ordering: .acquiring) {
                                    if ContinuousClock.now >= deadline { gate.timedOut.store(true, ordering: .releasing); break }
                                }
                            }
                        })
                    try device.stampDC(into: &stamp, state: state)
                    return true
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !gate.entered.load(ordering: .acquiring) {
                    guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("checkout gate timeout") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                var other = MatrixStamper(variableMap: topology.variableMap,
                    stampMatrix: { _, _, _ in }, stampRHS: { _, _ in }, stampValue: { _, _ in })
                do { try device.stampDC(into: &other, state: state); Issue.record("Concurrent evaluator ran") }
                catch { guard case OSDIAdapterFailure.busy = error else { throw error } }
                do { try lifetime.close(); Issue.record("Close crossed an active foreign/caller scope") }
                catch { guard case OSDIAdapterFailure.busy = error else { throw error } }
                gate.release.store(true, ordering: .releasing)
                #expect(try await group.next() == true)
                let didTimeOut = gate.timedOut.load(ordering: .acquiring)
                #expect(!didTimeOut)
                try lifetime.close()
                do { try device.stampDC(into: &other, state: state); Issue.record("Closed reference executed") }
                catch { guard case OSDIAdapterFailure.closed = error else { throw error } }
            }
            try prepared.close()
        } catch { do { try prepared.close() } catch { Issue.record("Cleanup failed") }; throw error }
        try await fixture.close()
    }

    private final class Gate: Sendable {
        let entered = Atomic<Bool>(false)
        let release = Atomic<Bool>(false)
        let timedOut = Atomic<Bool>(false)
    }

    @Test func callerReentryFailsBusyAndMissingAnalysisPrerequisitesRemainExplicit() async throws {
        let fixture = try OSDIAdapterFixture(descriptor: "linear_dc")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let device = try owner.bind(context: &context)
            let state = SolutionState(variables: [1], variableMap: topology.variableMap)
            var attempted = false, busy = false
            var outer = MatrixStamper(variableMap: topology.variableMap, stampMatrix: { _, _, _ in },
                stampRHS: { _, _ in }, stampValue: { _, _ in
                    if !attempted {
                        attempted = true
                        var inner = MatrixStamper(variableMap: topology.variableMap,
                            stampMatrix: { _, _, _ in }, stampRHS: { _, _ in }, stampValue: { _, _ in })
                        do { try device.stampDC(into: &inner, state: state) }
                        catch { if case OSDIAdapterFailure.busy = error { busy = true } }
                    }
                })
            try device.stampDC(into: &outer, state: state)
            #expect(attempted && busy)
            // The checkout was returned after callbacks, so a subsequent stamp succeeds.
            try device.stampDC(into: &outer, state: state)
            var ac = ComplexMatrixStamper(variableMap: topology.variableMap,
                stampMatrix: { _, _, _, _ in }, stampRHS: { _, _, _ in })
            do { try device.stampAC(into: &ac, state: state, omega: 1); Issue.record("AC without direct CSR was admitted") }
            catch { guard case OSDIAdapterFailure.invalidMatrixMapping = error else { throw error } }
            do {
                try device.stampTransient(into: &outer, state: state,
                    integration: IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 0))
                Issue.record("Transient was admitted")
            } catch { guard case OSDIAdapterFailure.transientSessionRequired = error else { throw error } }
            try prepared.close()
        } catch { do { try prepared.close() } catch { Issue.record("Cleanup failed") }; throw error }
        try await fixture.close()
    }
}
