import CoreSpiceCompactModels
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceMOSContracts
import Testing

@Suite("Exact 4.5 preparation admission and transfer", .timeLimit(.minutes(1)))
struct MOSPreparation45Tests {
    @Test func stressWorkIsChargedExactlyOnceAndLimitsAreRootOwned() throws {
        let resolved = try MOSPreparationFixture.resolve(.bsim4_4_5, instance: [("l", 1e-6), ("w", 1e-5)])
        var work: [UInt64] = []
        for ceiling in [UInt32(8), 16] {
            let control = MOSPreparationTestControl()
            let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions(stress: ceiling)), limits: MOSPreparationFixture.limits(), control: control)
            #expect(prepared.receipt.coldSetupCount == 1)
            work.append(control.work)
        }
        #expect(work[1] - work[0] == 8)
        for limits in [try MOSPreparationFixture.limits(bytes: 1), try MOSPreparationFixture.limits(temporary: 1)] {
            #expect(throws: MOSPreparationFailure.capacityExceeded) {
                _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                    conditions: MOSPreparationFixture.conditions(stress: 8)), limits: limits, control: MOSPreparationTestControl())
            }
        }
        #expect(throws: MOSPreparationFailure.cancelled) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions(stress: 8)), limits: MOSPreparationFixture.limits(),
                control: MOSPreparationTestControl(cancelAfter: 15))
        }
    }

    @Test func activatedNativeStressCeilingRemainsTypedWorkFailure() throws {
        let resolved = try MOSPreparationFixture.resolve(.bsim4_4_5,
            instance: [("l", 1e-6), ("w", 1e-5), ("nf", 2), ("sa", 1e-6), ("sb", 1e-6), ("sd", 1e-6)])
        #expect(throws: MOSPreparationFailure.workLimitExceeded) {
            _ = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions(stress: 1)), limits: MOSPreparationFixture.limits(),
                control: MOSPreparationTestControl())
        }
    }

    @Test func consumingBindRejectsConditionsCSRAndConflictingICWithoutClaims() throws {
        for mismatch in ["conditions", "csr", "ic"] {
            let resolved = try MOSPreparationFixture.resolve(.bsim4_4_5,
                model: [("rgatemod", 3), ("rbodymod", 1), ("rsh", 20), ("trnqsmod", 1)],
                instance: [("l", 1e-6), ("w", 1e-5), ("nrd", 1), ("nrs", 1), ("ic_vds", 1)])
            let prepared = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved,
                conditions: MOSPreparationFixture.conditions(stress: 8)), limits: MOSPreparationFixture.limits(), control: MOSPreparationTestControl())
            let instance = MOSPreparationFixture.instance(prepared.receipt,
                ports: mismatch == "ic" ? [.ground, Node(id: 2), .ground, Node(id: 4)] : nil)
            var context = try MOSPreparationFixture.context(instance,
                ambient: mismatch == "conditions" ? 350 : 300.15, csr: mismatch != "csr")
            do { _ = try prepared.bind(instance: instance, context: &context); Issue.record("Invalid transfer admitted") }
            catch { #expect(error == (mismatch == "conditions" ? .conditionsMismatch : mismatch == "csr" ? .invalidMatrixMapping : .terminalInitialConditionsConflict)) }
            try context.claimOwnedNodes(for: instance)
        }
    }
}
