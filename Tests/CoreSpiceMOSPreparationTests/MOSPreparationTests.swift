import CoreSpiceCompactModels
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceMOSContracts
import Synchronization
import Testing

@Suite("Single-owner native MOS preparation", .timeLimit(.minutes(1)))
struct MOSPreparationTests {
    @Test func level1AliasesPrepareCompileAndConsumeBindForBothPolarities() throws {
        for polarity in [MOSPolarity.nmos, .pmos] {
            let resolved = try MOSPreparationFixture.resolve(.level1, polarity: polarity)
            let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
            let typeName = polarity == .nmos ? "nmos" : "pmos"
            let instance = Instance(name: resolved.instance, typeName: typeName,
                nodes: (1...4).map { Node(id: $0) }, parameters: [:], mos: .prepared(prepared.receipt))
            let plan = try StandardCompiler().compile(ir: CircuitIR(nodes: instance.nodes, branches: [], instances: [instance]))
            let structure = plan.matrixStructure
            var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
                stampIndexResolver: { structure.index(row: $0, col: $1) })
            let bound = try prepared.bind(instance: plan.ir.instances[0], context: &context)
            #expect(bound.instance.typeName == typeName)
        }
    }

    @Test func supportedReleasesPrepareOnceAndBindActualPhysicalStamps() throws {
        for release in [MOSModelRelease.level1, .level2, .level3, .bsim3_3_3_0, .bsim4_4_8_3] {
            for polarity in [MOSPolarity.nmos, .pmos] {
                let resolved = try MOSPreparationFixture.resolve(release, polarity: polarity,
                    instance: [("l", 1e-6), ("w", 10e-6)])
                let control = MOSPreparationTestControl()
                let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                    conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: control)
                let receipt = prepared.receipt
                #expect(receipt.coldSetupCount == 1)
                #expect(receipt.identity.resolved == resolved)
                #expect(receipt.identity.implementationIdentity == NativeMOSDevicePreparer.implementationIdentity)
                let instance = MOSPreparationFixture.instance(receipt)
                var context = try MOSPreparationFixture.context(instance)
                let bound = try prepared.bind(instance: instance, context: &context)
                let count = Mutex(0)
                var stamper = MatrixStamper(variableMap: context.variableMap,
                    stampMatrix: { _, _, value in #expect(value.isFinite); count.withLock { $0 += 1 } },
                    stampRHS: { _, value in #expect(value.isFinite) },
                    stampValue: { _, value in #expect(value.isFinite); count.withLock { $0 += 1 } })
                let solution = SolutionState(variables: Array(repeating: 0, count: context.matrixDimension), variableMap: context.variableMap)
                try bound.stampDC(into: &stamper, state: solution)
                #expect(count.withLock { $0 } > 0)
                #expect(control.work > 0)
            }
        }
    }

    @Test func classicUnsupportedSuppliedValuesFailExplicitly() throws {
        for (name, value) in [("m", 2.0), ("off", 1.0), ("ic_vds", 0.0), ("ic_vgs", 1.0), ("ic_vbs", 0.0)] {
            let resolved = try MOSPreparationFixture.resolve(.level1, instance: [(name, value)])
            #expect(throws: MOSPreparationFailure.unsupportedInstanceParameter(name)) {
                _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                    conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(),
                    control: MOSPreparationTestControl())
            }
        }
    }

    @Test func inspected45AndLowStorageAndCancellationNeverPublishOwner() throws {
        let unsupported = try MOSPreparationFixture.resolve(.bsim4_4_5)
        #expect(throws: MOSPreparationFailure.unsupportedRelease(.bsim4_4_5)) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: unsupported,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
        }
        let resolved = try MOSPreparationFixture.resolve(.bsim4_4_8_3)
        for limits in [try MOSPreparationFixture.limits(bytes: 1), try MOSPreparationFixture.limits(temporary: 1)] {
            #expect(throws: MOSPreparationFailure.capacityExceeded) {
                _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                    conditions: MOSPreparationFixture.conditions()), limits: limits, control: MOSPreparationTestControl())
            }
        }
        #expect(throws: MOSPreparationFailure.cancelled) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl(cancelAfter: 4))
        }
    }

    @Test func differentConditionsRefuseConsumingBinding() throws {
        let resolved = try MOSPreparationFixture.resolve(.level1)
        for (ambient, nominal) in [(350.0, 300.15), (300.15, 350.0)] {
            let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
            let instance = MOSPreparationFixture.instance(prepared.receipt)
            var context = try MOSPreparationFixture.context(instance, ambient: ambient, nominal: nominal)
            do {
                _ = try prepared.bind(instance: instance, context: &context)
                Issue.record("Changed conditions admitted")
            } catch { #expect(error == .conditionsMismatch) }
        }
    }

    @Test func changedCapabilitiesReceiptRefusesConsumingBinding() throws {
        let resolved = try MOSPreparationFixture.resolve(.level1)
        let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
            conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
        let different = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
            conditions: MOSPreparationFixture.conditions(capabilities: .dc)), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
        let instance = MOSPreparationFixture.instance(different.receipt)
        var context = try MOSPreparationFixture.context(instance)
        do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Changed receipt admitted") }
        catch { #expect(error == .identityMismatch) }
    }

    @Test func failedCsrBindingLeavesPrivateNodesUnclaimed() throws {
        let resolved = try MOSPreparationFixture.resolve(.bsim3_3_3_0, model: [("rsh", 10)],
            instance: [("l", 1e-6), ("w", 10e-6), ("nrd", 1), ("nrs", 1)])
        let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
            conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
        let instance = MOSPreparationFixture.instance(prepared.receipt)
        #expect(instance.ownedNodes.count >= 2)
        var context = try MOSPreparationFixture.context(instance, csr: false)
        do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Missing CSR admitted") }
        catch { #expect(error == .invalidMatrixMapping) }
        try context.claimOwnedNodes(for: instance)
    }

    @Test func invalidLaterPrivateNodeDoesNotClaimEarlierValidNode() throws {
        let ports = (1...4).map { Node(id: $0) }, privateNode = Node(id: 5)
        let invalid = Instance(name: "bad", typeName: "nmos_l49", nodes: ports, parameters: [:], ownedNodes: [privateNode, .ground])
        var context = try MOSPreparationFixture.context(invalid)
        #expect(throws: DeviceBindingError.self) { try context.claimOwnedNodes(for: invalid) }
        let valid = Instance(name: "good", typeName: "nmos_l49", nodes: ports, parameters: [:], ownedNodes: [privateNode])
        try context.claimOwnedNodes(for: valid)
        #expect(throws: DeviceBindingError.self) { try context.claimOwnedNodes(for: valid) }
    }

    @Test func cancelledPreparedBindLeavesPrivateNodesUnclaimed() throws {
        let resolved = try MOSPreparationFixture.resolve(.bsim4_4_8_3, model: [("rsh", 10)], instance: [("nrd", 1), ("nrs", 1)])
        let control = MOSPreparationTestControl()
        let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
            conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: control)
        let instance = MOSPreparationFixture.instance(prepared.receipt)
        var context = try MOSPreparationFixture.context(instance)
        control.cancel()
        do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Cancelled binding admitted") }
        catch { #expect(error == .cancelled) }
        try context.claimOwnedNodes(for: instance)
    }

    @Test func conflictingTerminalIcBindingLeavesPrivateNodesUnclaimed() throws {
        for release in [MOSModelRelease.bsim3_3_3_0, .bsim4_4_8_3] {
            let resolved = try MOSPreparationFixture.resolve(release, model: [("rsh", 10)],
                instance: [("nrd", 1), ("nrs", 1), ("ic_vds", 1)])
            let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
            let instance = MOSPreparationFixture.instance(prepared.receipt,
                ports: [.ground, Node(id: 1), .ground, Node(id: 2)])
            #expect(!instance.ownedNodes.isEmpty)
            var context = try MOSPreparationFixture.context(instance)
            do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Conflicting terminal IC admitted") }
            catch { #expect(error == .terminalInitialConditionsConflict) }
            try context.claimOwnedNodes(for: instance)
        }
    }

    @Test func allocationMetadataUsesLinkedOwnersAndSafeStorageBudgetsRefuse() throws {
        #expect(BSIM3Evaluator.ownerAllocationBytes > 32768)
        #expect(BSIM4Evaluator.ownerAllocationBytes > 32768)
        let limits = try MOSPreparationFixture.limits(temporary: 1)
        #expect(throws: MOSPreparationFailure.capacityExceeded) {
            _ = try BSIM3Evaluator(configuration: .init(), preparationLimits: limits, preparationControl: MOSPreparationTestControl())
        }
    }

    @Test func retainedReceiptBytesAreAnEnforcedBoundary() throws {
        for release in [MOSModelRelease.bsim3_3_3_0, .bsim4_4_8_3] {
            let resolved = try MOSPreparationFixture.resolve(release)
            let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
            let bytes = prepared.receipt.retainedBytes
            #expect(throws: MOSPreparationFailure.capacityExceeded) {
                _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                    conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(bytes: bytes - 1),
                    control: MOSPreparationTestControl())
            }
            let exact = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(bytes: bytes),
                control: MOSPreparationTestControl())
            #expect(exact.receipt.retainedBytes == bytes)
        }
    }

    @Test func nonemptyDiagnosticPayloadIsMeasuredAndLimited() throws {
        let configuration = BSIM3Configuration(modelParameters: ["pb": 0.01, "a2": 0, "paramchk": 1])
        let evaluator = try BSIM3Evaluator(configuration: configuration,
            preparationLimits: MOSPreparationFixture.limits(), preparationControl: MOSPreparationTestControl())
        #expect(!evaluator.diagnostics.isEmpty)
        #expect(evaluator.diagnosticStorageBytes > 0)
        #expect(evaluator.preparationTemporaryBytes >= evaluator.diagnosticStorageBytes)
        let tight = try MOSPreparationLimits(maximumRetainedBytes: 8_000_000, maximumTemporaryBytes: 8_000_000,
            maximumDiagnosticBytes: evaluator.diagnosticStorageBytes - 1, maximumWorkUnits: 100_000)
        #expect(throws: MOSPreparationFailure.capacityExceeded) {
            _ = try BSIM3Evaluator(configuration: configuration, preparationLimits: tight,
                preparationControl: MOSPreparationTestControl())
        }
    }
}
