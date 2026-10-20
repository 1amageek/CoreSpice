import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import OSDIRuntime

/// Same actual spatial source and cleanup; callers must explicitly select its query domain.
internal enum NativePrescribedVoltageSpatialSource {
    enum QueryDomain { case lifted, original }
    typealias A = NativePrescribedVoltageArithmetic
    static func workspaceByteCount(activeCount: Int) throws -> Int {
        return try A.add(A.multiply(activeCount,
            4 * MemoryLayout<Double>.stride + MemoryLayout<Int?>.stride + MemoryLayout<Bool>.stride),
            4 * MemoryLayout<[Double]>.stride + MemoryLayout<[Int?]>.stride + MemoryLayout<[Bool]>.stride)
    }
    static func withRange(device: any BoundDevice, preparation: NativeOSDIPreparationRecord,
        original: OSDIConstitutiveCaptureRetention, values: NativePrescribedVoltageValues.Payload,
        query: QueryDomain, inputs: OSDISmoothRangeCaptureInputs,
        maximumWorkspaceBytes: Int, precisionBits: UInt32,
        control: any LinearSolverExecutionControlling, checkpoint: () throws -> Void,
        _ body: (OSDIPrecisionRangeEvaluationView, OSDIConstitutiveInventoryView) throws -> Void)
        async throws -> OSDISmoothRangeScope {
        let domain = values.originalDomain
        let lower: [CompensatedValue], upper: [CompensatedValue]
        switch query {
        case .lifted: lower = values.lower; upper = values.upper
        case .original: lower = domain.lower; upper = domain.upper
        }
        guard inputs.worker.expectedReference == original.workerReference,
              inputs.numericProfile == original.numericProfile, inputs.options == original.options else {
            throw NativePrescribedVoltageReconstructionFailure.invalidBinding
        }
        guard preparation.instanceName == device.instance.name,
              let program = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: device),
              program.topology == preparation.receipt.topology,
              program.modelReference == preparation.receipt.resolved.binding.artifact else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
        let topology = program.topology, activeCount = topology.activeUnknownCount, rawCount = topology.nodes.count
        let n = lower.count
        guard upper.count == n,
              preparation.rawNodeGlobalRows.count == rawCount else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
        let bytes = try workspaceByteCount(activeCount: activeCount)
        guard bytes <= maximumWorkspaceBytes else { throw NativePrescribedVoltageReconstructionFailure.capacityExceeded }
        let scratch = try control.reserveStorage(byteCount: bytes)
        defer { withExtendedLifetime(scratch) {} }
        try control.checkpoint(workUnits: A.multiply(activeCount, 6))
        var globals = [Int?](repeating: nil, count: activeCount)
        var assigned = [Bool](repeating: false, count: activeCount)
        for raw in 0..<rawCount {
            try checkpoint()
            let global = preparation.rawNodeGlobalRows[raw]
            if let global, !(0..<n).contains(global) { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
            guard let active = topology.nodes[raw].activeUnknownIndex else {
                guard global == nil else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }; continue
            }
            guard (0..<activeCount).contains(active), !assigned[active] || globals[active] == global else {
                throw NativePrescribedVoltageReconstructionFailure.invalidBinding
            }
            globals[active] = global; assigned[active] = true
        }
        var lh = [Double](repeating: 0, count: activeCount), ll = lh, uh = lh, ul = lh
        for active in 0..<activeCount {
            try checkpoint()
            guard assigned[active] else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
            let lo = globals[active].map { lower[$0] } ?? .zero, hi = globals[active].map { upper[$0] } ?? .zero
            lh[active] = lo.high; ll[active] = lo.low; uh[active] = hi.high; ul[active] = hi.low
        }
        var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: device, inputs: inputs)
        var closing = false
        do {
            try checkpoint()
            let scope = try capture.withCheckedRange(lowerHigh: lh.span, lowerLow: ll.span,
                upperHigh: uh.span, upperLow: ul.span, lowerContext: domain.lowerContext,
                upperContext: domain.upperContext, precisionBits: precisionBits) { view, inventory, scope in
                guard scope.source == original.source.source,
                      scope.workerReference == original.workerReference, scope.numericProfile == original.numericProfile,
                      scope.options == original.options, inventory.instanceName == preparation.instanceName,
                      inventory.matrixDimension == n, inventory.rawGlobal.count == rawCount,
                      inventory.activeGlobal.count == activeCount, scope.lowerContext == domain.lowerContext,
                      scope.upperContext == domain.upperContext else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
                try scope.withCoordinates { slh, sll, suh, sul in
                    guard slh.count == activeCount, sll.count == activeCount,
                          suh.count == activeCount, sul.count == activeCount else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
                    for active in 0..<activeCount {
                        try checkpoint()
                        guard inventory.activeGlobal[active] == globals[active],
                              slh[active].bitPattern == lh[active].bitPattern, sll[active].bitPattern == ll[active].bitPattern,
                              suh[active].bitPattern == uh[active].bitPattern, sul[active].bitPattern == ul[active].bitPattern else {
                            throw NativePrescribedVoltageReconstructionFailure.invalidBinding
                        }
                    }
                }
                let square = try A.multiply(rawCount, rawCount)
                guard view.cLower.count == square, view.cUpper.count == square else {
                    throw NativePrescribedVoltageReconstructionFailure.invalidBinding
                }
                for raw in 0..<rawCount {
                    try checkpoint()
                    guard inventory.rawGlobal[raw] == preparation.rawNodeGlobalRows[raw] else {
                        throw NativePrescribedVoltageReconstructionFailure.invalidBinding
                    }
                }
                try body(view, inventory)
                return scope
            }
            try checkpoint(); closing = true
            try capture.close()
            return scope
        } catch {
            let primary = error
            if closing { throw primary }
            do { try capture.close() }
            catch OSDISmoothRangeFailure.cleanupPending(let first, let second, let owner) {
                throw OSDISmoothRangeFailure.cleanupPending(
                    primary: .cleanup(primary: .control(primary), secondary: first), secondary: second, owner: owner)
            } catch let cleanup as OSDISmoothRangeFailure {
                throw OSDISmoothRangeFailure.cleanup(primary: .control(primary), secondary: cleanup)
            } catch {
                throw OSDISmoothRangeFailure.cleanup(primary: .control(primary), secondary: .control(error))
            }
            throw primary
        }
    }
}
