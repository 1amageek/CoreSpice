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
        for release in [MOSModelRelease.level1, .level2, .level3] {
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
                #expect(receipt.topology.localNodeCount == 4)
                #expect(receipt.topology.auxiliaryNodeCount == 0)
                #expect(receipt.peakTemporaryBytes == 0)
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

    @Test func lowStorageWorkAndCancellationNeverPublishOwner() throws {
        let resolved = try MOSPreparationFixture.resolve(.level1, instance: [("w", 1e-5), ("l", 1e-6)])
        #expect(throws: MOSPreparationFailure.capacityExceeded) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(bytes: 1),
                control: MOSPreparationTestControl())
        }
        #expect(throws: MOSPreparationFailure.workLimitExceeded) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(work: 1),
                control: MOSPreparationTestControl())
        }
        #expect(throws: MOSPreparationFailure.cancelled) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(),
                control: MOSPreparationTestControl(cancelAfter: 1))
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

    @Test func classicBindingRequiresEveryCompiledCsrPair() throws {
        let resolved = try MOSPreparationFixture.resolve(.level3)
        let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
            conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
        let instance = MOSPreparationFixture.instance(prepared.receipt)
        #expect(instance.ownedNodes.isEmpty)
        var context = try MOSPreparationFixture.context(instance, csr: false)
        do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Missing CSR admitted") }
        catch { #expect(error == .invalidMatrixMapping) }
    }

    @Test func cancelledClassicPreparedBindFailsBeforePublication() throws {
        let resolved = try MOSPreparationFixture.resolve(.level2)
        let control = MOSPreparationTestControl()
        let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
            conditions: MOSPreparationFixture.conditions()), limits: MOSPreparationFixture.limits(), control: control)
        let instance = MOSPreparationFixture.instance(prepared.receipt)
        var context = try MOSPreparationFixture.context(instance)
        control.cancel()
        do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Cancelled binding admitted") }
        catch { #expect(error == .cancelled) }
    }

    @Test func retainedReceiptBytesAreAnEnforcedBoundary() throws {
        for release in [MOSModelRelease.level1, .level2, .level3] {
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

    @Test func standardRegistryContainsOnlyClassicNativeMosDescriptors() {
        let registry = DeviceRegistry.standard()
        for type in ["nmos_l1", "pmos_l1", "nmos_l2", "pmos_l2", "nmos_l3", "pmos_l3"] {
            #expect(registry.descriptor(for: type) != nil)
        }
        for type in ["nmos_l49", "pmos_l49", "nmos_l54", "pmos_l54"] {
            #expect(registry.descriptor(for: type) == nil)
        }
    }
}
