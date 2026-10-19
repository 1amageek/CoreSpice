import CoreSpiceDevices
import OSDIRuntime

package protocol OSDIConstitutiveCapturePreparing: BoundDevice {
    func prepareConstitutiveCapture(inputs: OSDIConstitutiveCaptureInputs) async throws -> OSDIConstitutiveCapture
}

extension BoundOSDIDevice: OSDIConstitutiveCapturePreparing {
    func prepareConstitutiveCapture(inputs: OSDIConstitutiveCaptureInputs) async throws -> OSDIConstitutiveCapture {
        guard let snapshot = constitutiveSnapshot else { throw OSDIConstitutiveCaptureFailure.missingSnapshot }
        let control = snapshot.control
        try control.checkpoint(workUnits: 0)
        try owner.validateConstitutiveCaptureAvailability()
        guard case .prepared(let receipt) = instance.osdi,
              snapshot.program.modelReference == receipt.resolved.binding.artifact,
              Int(snapshot.program.descriptorIndex) == receipt.resolved.binding.descriptorIndex,
              snapshot.program.topology == receipt.topology, inputs.options == snapshot.options else {
            throw OSDIConstitutiveCaptureFailure.invalidBinding
        }
        let inventory = try OSDIConstitutiveInventory(instanceName: instance.name, mapping: mapping,
            topology: snapshot.program.topology, control: control)
        let helperLease = try control.reserveStorage(byteCount: OSDIConstitutiveCapacity.helper(options: inputs.options))
        // Scheduled upper allowance, not measured consumed work. Never refunded.
        try control.checkpoint(workUnits: OSDIConstitutiveCapacity.integer(inputs.options.maximumWorkUnits))
        do {
            let session = try await inputs.preparer.prepareConstitutiveIdentities(program: snapshot.program,
                worker: inputs.worker, source: inputs.source, numericProfile: inputs.numericProfile,
                options: inputs.options, coverLimits: inputs.coverLimits, limits: inputs.limits,
                coordinateQuotient: inventory.quotient)
            let matches = session.chartBinding == OSDIPrecisionChartBinding(program: snapshot.program)
                && session.workerReference == inputs.worker.expectedReference && session.numericProfile == inputs.numericProfile
                && session.options == inputs.options && session.coordinateQuotient == inventory.quotient
                && session.decisionCoverLimits == inputs.coverLimits && session.constitutiveLimits == inputs.limits
            var capture = OSDIConstitutiveCapture(session: consume session, snapshot: snapshot,
                inventory: inventory, evaluator: inputs.evaluator, helperLease: helperLease)
            do {
                guard matches else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
                try control.checkpoint(workUnits: 0)
            }
            catch {
                let primary = OSDIConstitutiveCaptureFailure.wrapping(error)
                do { try capture.close() }
                catch { throw OSDIConstitutiveCaptureFailure.cleanup(primary: primary, secondary: .wrapping(error)) }
                throw primary
            }
            return consume capture
        } catch {
            if let failure = error as? OSDIConstitutiveCaptureFailure { throw failure }
            let primary = OSDIConstitutiveCaptureFailure.wrapping(error)
            if let pending = OSDIConstitutiveCaptureFailure.pending(error) {
                throw OSDIConstitutiveCaptureFailure.cleanupPending(primary: primary, secondary: nil,
                    owner: OSDIConstitutiveCaptureCleanup(pending: pending, lease: helperLease))
            }
            throw primary
        }
    }
}
