import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import OSDIRuntime

/// Same-source complete-cover F/Q values on the already contained global lifted box.
internal enum NativePrescribedVoltageSourceValues {
    typealias A = NativePrescribedVoltageArithmetic
    static func enclose(device: any BoundDevice, preparation: NativeOSDIPreparationRecord,
        domain: NativeGlobalChargeDomain, lower: [CompensatedValue], upper: [CompensatedValue],
        inputs: OSDIConstitutiveCaptureInputs, limits: NativePrescribedVoltageLimits,
        control: any LinearSolverExecutionControlling, f: inout [CompensatedEnclosure],
        q: inout [CompensatedEnclosure], checkpoint: () throws -> Void) async throws -> OSDIConstitutiveCaptureRetention {
        guard preparation.instanceName == device.instance.name,
              let program = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: device),
              program.topology == preparation.receipt.topology,
              program.modelReference == preparation.receipt.resolved.binding.artifact else { throw NativePrescribedVoltageFailure.invalidBinding }
        let topology = program.topology, activeCount = topology.activeUnknownCount, rawCount = topology.nodes.count
        let n = lower.count
        guard upper.count == n, f.count == n, q.count == n,
              preparation.rawNodeGlobalRows.count == rawCount else { throw NativePrescribedVoltageFailure.invalidBinding }
        let bytes = try A.add(A.multiply(activeCount,
            4 * MemoryLayout<Double>.stride + MemoryLayout<Int?>.stride + MemoryLayout<Bool>.stride),
            4 * MemoryLayout<[Double]>.stride + MemoryLayout<[Int?]>.stride + MemoryLayout<[Bool]>.stride)
        guard bytes <= limits.maximumWorkspaceBytes else { throw NativePrescribedVoltageFailure.capacityExceeded }
        let scratch = try control.reserveStorage(byteCount: bytes)
        defer { withExtendedLifetime(scratch) {} }
        try control.checkpoint(workUnits: A.multiply(activeCount, 6))
        var globals = [Int?](repeating: nil, count: activeCount)
        var assigned = [Bool](repeating: false, count: activeCount)
        for raw in 0..<rawCount {
            try checkpoint()
            let global = preparation.rawNodeGlobalRows[raw]
            if let global, !(0..<n).contains(global) { throw NativePrescribedVoltageFailure.invalidBinding }
            guard let active = topology.nodes[raw].activeUnknownIndex else {
                guard global == nil else { throw NativePrescribedVoltageFailure.invalidBinding }; continue
            }
            guard (0..<activeCount).contains(active), !assigned[active] || globals[active] == global else {
                throw NativePrescribedVoltageFailure.invalidBinding
            }
            globals[active] = global; assigned[active] = true
        }
        var lh = [Double](repeating: 0, count: activeCount), ll = lh, uh = lh, ul = lh
        for active in 0..<activeCount {
            try checkpoint()
            guard assigned[active] else { throw NativePrescribedVoltageFailure.invalidBinding }
            let lo = globals[active].map { lower[$0] } ?? .zero, hi = globals[active].map { upper[$0] } ?? .zero
            lh[active] = lo.high; ll[active] = lo.low; uh[active] = hi.high; ul[active] = hi.low
        }
        var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareCapture(of: device, inputs: inputs)
        var closing = false
        do {
            try checkpoint()
            let retention = try capture.withCheckedIdentities(lowerHigh: lh.span, lowerLow: ll.span,
                upperHigh: uh.span, upperLow: ul.span, lowerContext: domain.lowerContext,
                upperContext: domain.upperContext, precisionBits: limits.precisionBits) { view, inventory in
                guard let retention = inventory.retention, inventory.instanceName == preparation.instanceName,
                      inventory.matrixDimension == n, inventory.rawGlobal.count == rawCount,
                      inventory.activeGlobal.count == activeCount,
                      view.cover.lowerContext == domain.lowerContext, view.cover.upperContext == domain.upperContext,
                      view.cover.lowerHigh.count == activeCount, view.cover.lowerLow.count == activeCount,
                      view.cover.upperHigh.count == activeCount, view.cover.upperLow.count == activeCount,
                      view.cover.leafCount > 0 else { throw NativePrescribedVoltageFailure.invalidBinding }
                for active in 0..<activeCount {
                    try checkpoint()
                    guard inventory.activeGlobal[active] == globals[active],
                          view.cover.lowerHigh[active].bitPattern == lh[active].bitPattern,
                          view.cover.lowerLow[active].bitPattern == ll[active].bitPattern,
                          view.cover.upperHigh[active].bitPattern == uh[active].bitPattern,
                          view.cover.upperLow[active].bitPattern == ul[active].bitPattern else { throw NativePrescribedVoltageFailure.invalidBinding }
                }
                for raw in 0..<rawCount {
                    try checkpoint()
                    guard inventory.rawGlobal[raw] == preparation.rawNodeGlobalRows[raw] else { throw NativePrescribedVoltageFailure.invalidBinding }
                    var flo = Double.infinity, fhi = -Double.infinity, qlo = Double.infinity, qhi = -Double.infinity
                    for leaf in 0..<view.cover.leafCount {
                        try checkpoint()
                        let output = view.cover.withLeaf(at: leaf) { value -> (Double, Double, Double, Double)? in
                            guard value.fLower.count == rawCount, value.fUpper.count == rawCount,
                                  value.qLower.count == rawCount, value.qUpper.count == rawCount else { return nil }
                            return (value.fLower[raw], value.fUpper[raw], value.qLower[raw], value.qUpper[raw])
                        }
                        guard let output, output.0.isFinite, output.1.isFinite, output.2.isFinite, output.3.isFinite,
                              output.0 <= output.1, output.2 <= output.3 else { throw NativePrescribedVoltageFailure.invalidBinding }
                        flo = min(flo, output.0); fhi = max(fhi, output.1)
                        qlo = min(qlo, output.2); qhi = max(qhi, output.3)
                    }
                    let fv = try A.hull(flo, fhi), qv = try A.hull(qlo, qhi)
                    if let global = inventory.rawGlobal[raw] {
                        f[global] = try f[global].adding(fv); q[global] = try q[global].adding(qv)
                    }
                }
                return retention
            }
            try checkpoint(); closing = true
            try capture.close()
            return retention
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
