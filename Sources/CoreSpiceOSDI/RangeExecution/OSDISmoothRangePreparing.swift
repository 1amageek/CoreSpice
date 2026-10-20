import OSDIContracts
import OSDIRuntime

extension BoundOSDIDevice {
    func prepareSmoothRangeCapture(inputs: OSDISmoothRangeCaptureInputs) async throws -> OSDISmoothRangeCapture {
        guard let snapshot = constitutiveSnapshot else { throw OSDISmoothRangeFailure.missingSnapshot }
        let control = snapshot.control
        try control.checkpoint(workUnits: 0)
        try owner.validateConstitutiveCaptureAvailability()
        guard case .prepared(let receipt) = instance.osdi,
              snapshot.program.modelReference == receipt.resolved.binding.artifact,
              Int(snapshot.program.descriptorIndex) == receipt.resolved.binding.descriptorIndex,
              snapshot.program.topology == receipt.topology, inputs.options == snapshot.options else {
            throw OSDISmoothRangeFailure.invalidBinding
        }
        let inventory = try OSDIConstitutiveInventory(instanceName: instance.name, mapping: mapping,
            topology: snapshot.program.topology, control: control)
        let bytes = try OSDIConstitutiveCapacity.add(
            OSDIConstitutiveCapacity.add(OSDIConstitutiveCapacity.integer(inputs.options.maximumMappingBytes),
                OSDIConstitutiveCapacity.integer(inputs.options.arenaBytes)),
            OSDIConstitutiveCapacity.add(MemoryLayout<OSDISmoothRangeCapture>.stride,
                OSDIConstitutiveCapacity.add(OSDISmoothRangeStorage.logicalStateBytes, OSDIConstitutiveCaptureCleanup.logicalStateBytes)))
        let lease = try control.reserveStorage(byteCount: bytes)
        // Scheduled upper allowance on the original owner, never a refunded measurement.
        try control.checkpoint(workUnits: OSDIConstitutiveCapacity.integer(inputs.options.maximumWorkUnits))
        do {
            let session = try await inputs.preparer.prepareRange(program: snapshot.program, worker: inputs.worker,
                source: inputs.source, numericProfile: inputs.numericProfile, options: inputs.options)
            let matches = session.chartBinding == OSDIPrecisionChartBinding(program: snapshot.program)
                && session.workerReference == inputs.worker.expectedReference && session.numericProfile == inputs.numericProfile
                && session.options == inputs.options && session.coordinateQuotient == nil
                && session.decisionCoverLimits == nil && session.constitutiveLimits == nil && session.chartLimits == nil
            var capture = OSDISmoothRangeCapture(session: consume session, snapshot: snapshot, inventory: inventory, lease: lease)
            do {
                guard matches else { throw OSDISmoothRangeFailure.invalidBinding }
                try control.checkpoint(workUnits: 0)
            } catch {
                let primary = OSDISmoothRangeFailure.wrapping(error)
                do { try capture.close() }
                catch { throw OSDISmoothRangeFailure.cleanup(primary: primary, secondary: .wrapping(error)) }
                throw primary
            }
            return consume capture
        } catch {
            if let failure = error as? OSDISmoothRangeFailure { throw failure }
            let primary = OSDISmoothRangeFailure.wrapping(error)
            if let pending = (error as? OSDIError).flatMap({ OSDIExecutionOwner.pendingCleanup($0) }) {
                throw OSDISmoothRangeFailure.cleanupPending(primary: primary, secondary: nil,
                    owner: OSDIConstitutiveCaptureCleanup(pending: pending, lease: lease))
            }
            throw primary
        }
    }
}
