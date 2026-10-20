import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import OSDIRuntime

/// Full-original-domain local identities, without global completion or anchor construction.
internal enum NativePrescribedVoltageChartSourceIdentity {
    typealias A = NativePrescribedVoltageArithmetic
    static func check(device: any BoundDevice, preparation: NativeOSDIPreparationRecord,
        values: NativePrescribedVoltageValues.Payload, original: OSDIConstitutiveCaptureRetention,
        globalAlgebraic: [Int], inputs: OSDIConstitutiveCaptureInputs,
        limits: NativePrescribedVoltageChartLimits, exact: ExactRowAlgebra,
        retained: inout NativeGlobalChargeArithmetic.Retained,
        control: any LinearSolverExecutionControlling, checkpoint: () throws -> Void)
        async throws -> NativeGlobalChargeKernel.LocalProof {
        let domain = values.originalDomain, lower = domain.lower, upper = domain.upper
        guard inputs.worker.expectedReference == original.workerReference,
              inputs.numericProfile == original.numericProfile, inputs.options == original.options,
              inputs.coverLimits == original.coverLimits, inputs.limits == original.identityLimits else {
            throw NativePrescribedVoltageChartFailure.invalidBinding
        }
        guard preparation.instanceName == device.instance.name,
              let program = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: device),
              program.topology == preparation.receipt.topology,
              program.modelReference == preparation.receipt.resolved.binding.artifact else { throw NativePrescribedVoltageChartFailure.invalidBinding }
        let topology = program.topology, activeCount = topology.activeUnknownCount, rawCount = topology.nodes.count
        let n = lower.count
        guard rawCount <= limits.exact.maximumColumns else { throw ExactRowAlgebra.Failure.invalidInput }
        guard upper.count == n, globalAlgebraic.count == n,
              preparation.rawNodeGlobalRows.count == rawCount else { throw NativePrescribedVoltageChartFailure.invalidBinding }
        let projectionBytes = try A.add(A.multiply(activeCount,
            4 * MemoryLayout<Double>.stride + MemoryLayout<Int?>.stride + MemoryLayout<Bool>.stride),
            4 * MemoryLayout<[Double]>.stride + MemoryLayout<[Int?]>.stride + MemoryLayout<[Bool]>.stride)
        let bytes = try A.add(projectionBytes, A.add(A.multiply(rawCount, MemoryLayout<ExactRowAlgebra.Scalar>.stride), MemoryLayout<[ExactRowAlgebra.Scalar]>.stride))
        guard bytes <= limits.maximumWorkspaceBytes else { throw NativePrescribedVoltageChartFailure.capacityExceeded }
        let scratch = try control.reserveStorage(byteCount: bytes)
        defer { withExtendedLifetime(scratch) {} }
        try control.checkpoint(workUnits: A.multiply(activeCount, 6))
        var globals = [Int?](repeating: nil, count: activeCount)
        var assigned = [Bool](repeating: false, count: activeCount)
        for raw in 0..<rawCount {
            try checkpoint()
            let global = preparation.rawNodeGlobalRows[raw]
            if let global, !(0..<n).contains(global) { throw NativePrescribedVoltageChartFailure.invalidBinding }
            guard let active = topology.nodes[raw].activeUnknownIndex else {
                guard global == nil else { throw NativePrescribedVoltageChartFailure.invalidBinding }; continue
            }
            guard (0..<activeCount).contains(active), !assigned[active] || globals[active] == global else {
                throw NativePrescribedVoltageChartFailure.invalidBinding
            }
            globals[active] = global; assigned[active] = true
        }
        var lh = [Double](repeating: 0, count: activeCount), ll = lh, uh = lh, ul = lh
        for active in 0..<activeCount {
            try checkpoint()
            guard assigned[active] else { throw NativePrescribedVoltageChartFailure.invalidBinding }
            let lo = globals[active].map { lower[$0] } ?? .zero, hi = globals[active].map { upper[$0] } ?? .zero
            lh[active] = lo.high; ll[active] = lo.low; uh[active] = hi.high; ul[active] = hi.low
        }
        try control.checkpoint(workUnits: rawCount)
        var query = [ExactRowAlgebra.Scalar](repeating: .zero, count: rawCount)
        var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareCapture(of: device, inputs: inputs)
        var closing = false
        do {
            try checkpoint()
            let proof = try capture.withCheckedIdentities(lowerHigh: lh.span, lowerLow: ll.span,
                upperHigh: uh.span, upperLow: ul.span, lowerContext: domain.lowerContext,
                upperContext: domain.upperContext, precisionBits: limits.precisionBits) { view, inventory in
                guard let retention = inventory.retention, inventory.instanceName == preparation.instanceName,
                      inventory.matrixDimension == n, inventory.rawGlobal.count == rawCount,
                      inventory.activeGlobal.count == activeCount,
                      view.cover.lowerContext == domain.lowerContext, view.cover.upperContext == domain.upperContext,
                      view.cover.lowerHigh.count == activeCount, view.cover.lowerLow.count == activeCount,
                      view.cover.upperHigh.count == activeCount, view.cover.upperLow.count == activeCount,
                      view.cover.leafCount > 0 else { throw NativePrescribedVoltageChartFailure.invalidBinding }
                for active in 0..<activeCount {
                    try checkpoint()
                    guard inventory.activeGlobal[active] == globals[active],
                          view.cover.lowerHigh[active].bitPattern == lh[active].bitPattern,
                          view.cover.lowerLow[active].bitPattern == ll[active].bitPattern,
                          view.cover.upperHigh[active].bitPattern == uh[active].bitPattern,
                          view.cover.upperLow[active].bitPattern == ul[active].bitPattern else { throw NativePrescribedVoltageChartFailure.invalidBinding }
                }
                guard retention.source == original.source,
                      retention.workerReference == original.workerReference,
                      retention.numericProfile == original.numericProfile,
                      retention.options == original.options, retention.coverLimits == original.coverLimits,
                      retention.identityLimits == original.identityLimits else {
                    throw NativePrescribedVoltageChartFailure.invalidBinding
                }
                for raw in 0..<rawCount {
                    try checkpoint()
                    guard inventory.rawGlobal[raw] == preparation.rawNodeGlobalRows[raw] else {
                        throw NativePrescribedVoltageChartFailure.invalidBinding
                    }
                }
                let local = try NativeGlobalChargeSourceCapture.reactiveRows(view: view, rawCount: rawCount,
                    limits: limits.exact, retained: &retained, checkpoint: checkpoint)
                // At most rawCount selectors touch this source; repeated raw aliases are one query.
                for raw in 0..<rawCount {
                    try checkpoint()
                    guard let global = inventory.rawGlobal[raw], globalAlgebraic[global] >= 0 else { continue }
                    let selected = globalAlgebraic[global]
                    var repeated = false
                    for earlier in 0..<raw {
                        try checkpoint()
                        if let previous = inventory.rawGlobal[earlier], globalAlgebraic[previous] == selected { repeated = true }
                    }
                    if repeated { continue }
                    for column in 0..<rawCount {
                        try checkpoint()
                        let hit = inventory.rawGlobal[column].map { globalAlgebraic[$0] == selected } ?? false
                        query[column] = hit ? .one : .zero
                    }
                    let membership = try exact.membership(rows: local, query: query)
                    guard case .member = membership.certificate else { throw NativePrescribedVoltageChartFailure.unprovedNullRow }
                }
                try retained.array(CompensatedValue.self, count: A.multiply(activeCount, 2))
                var lo = [CompensatedValue](repeating: .zero, count: activeCount), hi = lo
                for active in 0..<activeCount {
                    try checkpoint()
                    lo[active] = try .init(high: lh[active], low: ll[active])
                    hi[active] = try .init(high: uh[active], low: ul[active])
                }
                return NativeGlobalChargeKernel.LocalProof(retention: retention, rows: local,
                    lower: lo, upper: hi, lowerContext: domain.lowerContext, upperContext: domain.upperContext,
                    usedPrecisionBits: view.cover.usedPrecisionBits, anchorPrecisionBits: [])
            }
            try checkpoint(); closing = true
            try capture.close()
            return proof
        } catch {
            let primary = error
            if closing { throw primary }
            do { try capture.close() }
            catch OSDIConstitutiveCaptureFailure.cleanupPending(let first, let second, let owner) {
                throw OSDIConstitutiveCaptureFailure.cleanupPending(
                    primary: .cleanup(primary: .control(primary), secondary: first), secondary: second, owner: owner)
            } catch let cleanup as OSDIConstitutiveCaptureFailure {
                throw OSDIConstitutiveCaptureFailure.cleanup(primary: .control(primary), secondary: cleanup)
            } catch {
                throw OSDIConstitutiveCaptureFailure.cleanup(primary: .control(primary), secondary: .control(error))
            }
            throw primary
        }
    }
}
