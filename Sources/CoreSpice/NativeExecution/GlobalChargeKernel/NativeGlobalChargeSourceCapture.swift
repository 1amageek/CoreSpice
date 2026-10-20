import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import OSDIContracts
import OSDIRuntime

/// Imports only actual full-domain identities; anchor identities never enter the proof basis.
internal enum NativeGlobalChargeSourceCapture {
    typealias A = NativeGlobalChargeArithmetic
    typealias Scalar = ExactRowAlgebra.Scalar
    /// Imports only the actual reactive identities of the checked full-domain capture.
    static func reactiveRows(view: borrowing OSDIPrecisionConstitutiveEvaluationView, rawCount: Int,
        limits: ExactRowAlgebra.Limits, retained: inout A.Retained,
        checkpoint: () throws -> Void) throws -> ExactRowAlgebra.Rows {
        var count = 0
        for claim in 0..<view.claimCount {
            try checkpoint()
            if view.withClaim(at: claim, { $0.kind == .reactive }) { count = try A.add(count, 1) }
        }
        guard count <= limits.maximumRows else { throw ExactRowAlgebra.Failure.invalidInput }
        let cells = try A.multiply(count, rawCount)
        try retained.array(Scalar.self, count: cells)
        var coefficients = [Scalar](repeating: .zero, count: cells), destination = 0
        for claim in 0..<view.claimCount {
            let imported: Swift.Result<Void, any Error> = view.withClaim(at: claim) { row in
                Swift.Result {
                    guard row.kind == .reactive else { return }
                    guard row.rawRowCount == rawCount else { throw NativeGlobalChargeFailure.invalidBinding }
                    for raw in 0..<rawCount {
                        try checkpoint()
                        let copied: Swift.Result<Scalar, any Error> = row.withCoefficient(at: raw) { value in
                            Swift.Result { try retained.scalar(negative: value.negative,
                                denominatorPower: value.denominatorPower, words: value.numeratorWords,
                                maximumBits: limits.maximumIntegerBits) }
                        }
                        coefficients[destination] = try copied.get(); destination += 1
                    }
                }
            }
            try imported.get()
        }
        guard destination == cells else { throw NativeGlobalChargeFailure.invalidBinding }
        return .init(rowCount: count, columnCount: rawCount, values: coefficients)
    }
    static func check(device: any BoundDevice, preparation: NativeOSDIPreparationRecord,
        domain: NativeGlobalChargeDomain, anchors: [NativeGlobalChargeAnchor], rows: ExactRowAlgebra.Rows,
        captureInputs: OSDIConstitutiveCaptureInputs, limits: NativeGlobalChargeLimits,
        exact: ExactRowAlgebra, control: any LinearSolverExecutionControlling,
        retained: inout A.Retained, charges: inout [CompensatedEnclosure],
        checkpoint: () throws -> Void) async throws -> NativeGlobalChargeKernel.LocalProof {
        let topology = preparation.receipt.topology
        let activeCount = topology.activeUnknownCount, rawCount = topology.nodes.count, n = rows.columnCount
        guard preparation.rawNodeGlobalRows.count == rawCount,
              let program = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: device),
              program.topology == topology,
              program.modelReference == preparation.receipt.resolved.binding.artifact else {
            throw NativeGlobalChargeFailure.invalidBinding
        }
        var bytes = try A.multiply(activeCount, 4 * MemoryLayout<Double>.stride + MemoryLayout<Int?>.stride + MemoryLayout<Bool>.stride)
        bytes = try A.add(bytes, A.multiply(rawCount, MemoryLayout<Scalar>.stride))
        bytes = try A.add(bytes, 4 * MemoryLayout<[Double]>.stride + MemoryLayout<[Int?]>.stride
            + MemoryLayout<[Bool]>.stride + MemoryLayout<[Scalar]>.stride)
        guard bytes <= limits.maximumWorkspaceBytes else { throw NativeGlobalChargeFailure.capacityExceeded }
        let scratch = try control.reserveStorage(byteCount: bytes)
        defer { withExtendedLifetime(scratch) {} }
        try control.checkpoint(workUnits: A.add(A.multiply(activeCount, 6), rawCount))
        var globals = [Int?](repeating: nil, count: activeCount)
        var assigned = [Bool](repeating: false, count: activeCount)
        for raw in 0..<rawCount {
            try checkpoint()
            let global = preparation.rawNodeGlobalRows[raw]
            if let global, !(0..<n).contains(global) { throw NativeGlobalChargeFailure.invalidBinding }
            guard let active = topology.nodes[raw].activeUnknownIndex else {
                guard global == nil else { throw NativeGlobalChargeFailure.invalidBinding }; continue
            }
            guard (0..<activeCount).contains(active), !assigned[active] || globals[active] == global else {
                throw NativeGlobalChargeFailure.invalidBinding
            }
            globals[active] = global; assigned[active] = true
        }
        for active in 0..<activeCount { try checkpoint(); guard assigned[active] else { throw NativeGlobalChargeFailure.invalidBinding } }
        var lowerHigh = [Double](repeating: 0, count: activeCount), lowerLow = lowerHigh
        var upperHigh = lowerHigh, upperLow = lowerHigh
        var query = [Scalar](repeating: .zero, count: rawCount)
        func validate(_ view: OSDIPrecisionConstitutiveEvaluationView, _ inventory: OSDIConstitutiveInventoryView,
            lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext) throws {
            guard inventory.instanceName == preparation.instanceName, inventory.matrixDimension == n,
                  inventory.rawGlobal.count == rawCount, inventory.activeGlobal.count == activeCount,
                  view.cover.lowerContext == lowerContext, view.cover.upperContext == upperContext,
                  view.cover.lowerHigh.count == activeCount, view.cover.lowerLow.count == activeCount,
                  view.cover.upperHigh.count == activeCount, view.cover.upperLow.count == activeCount else {
                throw NativeGlobalChargeFailure.invalidBinding
            }
            for raw in 0..<rawCount { try checkpoint(); guard inventory.rawGlobal[raw] == preparation.rawNodeGlobalRows[raw] else { throw NativeGlobalChargeFailure.invalidBinding } }
            for active in 0..<activeCount {
                try checkpoint()
                guard inventory.activeGlobal[active] == globals[active],
                      view.cover.lowerHigh[active].bitPattern == lowerHigh[active].bitPattern,
                      view.cover.lowerLow[active].bitPattern == lowerLow[active].bitPattern,
                      view.cover.upperHigh[active].bitPattern == upperHigh[active].bitPattern,
                      view.cover.upperLow[active].bitPattern == upperLow[active].bitPattern else {
                    throw NativeGlobalChargeFailure.invalidBinding
                }
            }
        }
        for active in 0..<activeCount {
            try checkpoint()
            let lo = globals[active].map { domain.lower[$0] } ?? .zero
            let hi = globals[active].map { domain.upper[$0] } ?? .zero
            lowerHigh[active] = lo.high; lowerLow[active] = lo.low
            upperHigh[active] = hi.high; upperLow[active] = hi.low
        }
        var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareCapture(of: device, inputs: captureInputs)
        var closing = false
        do {
            try checkpoint()
            let domainProof = try capture.withCheckedIdentities(lowerHigh: lowerHigh.span, lowerLow: lowerLow.span,
                upperHigh: upperHigh.span, upperLow: upperLow.span, lowerContext: domain.lowerContext,
                upperContext: domain.upperContext, precisionBits: limits.precisionBits) { view, inventory in
                try validate(view, inventory, lowerContext: domain.lowerContext, upperContext: domain.upperContext)
                guard let retention = inventory.retention else { throw NativeGlobalChargeFailure.invalidBinding }
                let local = try reactiveRows(view: view, rawCount: rawCount, limits: limits.exact,
                    retained: &retained, checkpoint: checkpoint)
                for row in 0..<rows.rowCount {
                    for raw in 0..<rawCount {
                        try checkpoint()
                        // Ground's global covector value is zero; conservation is not copied onto it.
                        query[raw] = inventory.rawGlobal[raw].map { rows.values[row * n + $0] } ?? .zero
                    }
                    let checked = try exact.membership(rows: local, query: query)
                    guard case .member = checked.certificate else { throw NativeGlobalChargeFailure.unprovedNullRow }
                }
                try retained.array(CompensatedValue.self, count: A.multiply(activeCount, 2))
                var lo = [CompensatedValue](repeating: .zero, count: activeCount), hi = lo
                for active in 0..<activeCount {
                    try checkpoint()
                    lo[active] = try .init(high: view.cover.lowerHigh[active], low: view.cover.lowerLow[active])
                    hi[active] = try .init(high: view.cover.upperHigh[active], low: view.cover.upperLow[active])
                }
                return (retention, local, lo, hi, view.cover.usedPrecisionBits)
            }
            try retained.array(UInt32.self, count: anchors.count)
            var anchorBits = [UInt32](repeating: 0, count: anchors.count)
            for anchor in anchors.indices {
                for active in 0..<activeCount {
                    try checkpoint()
                    let value = globals[active].map { anchors[anchor].coordinates[$0] } ?? .zero
                    lowerHigh[active] = value.high; lowerLow[active] = value.low
                    upperHigh[active] = value.high; upperLow[active] = value.low
                }
                try capture.withCheckedIdentities(lowerHigh: lowerHigh.span, lowerLow: lowerLow.span,
                    upperHigh: upperHigh.span, upperLow: upperLow.span,
                    lowerContext: anchors[anchor].context, upperContext: anchors[anchor].context,
                    precisionBits: limits.precisionBits) { view, inventory in
                    try validate(view, inventory, lowerContext: anchors[anchor].context, upperContext: anchors[anchor].context)
                    guard view.binding == domainProof.0.source, view.cover.leafCount > 0 else { throw NativeGlobalChargeFailure.invalidBinding }
                    anchorBits[anchor] = view.cover.usedPrecisionBits
                    // Every raw row, including ground, and every original terminal is consumed.
                    for raw in 0..<rawCount {
                        var lower = Double.infinity, upper = -Double.infinity
                        for leaf in 0..<view.cover.leafCount {
                            try checkpoint()
                            let values = view.cover.withLeaf(at: leaf) { output -> (Double, Double)? in
                                guard output.qLower.count == rawCount, output.qUpper.count == rawCount else { return nil }
                                return (output.qLower[raw], output.qUpper[raw])
                            }
                            guard let values, values.0.isFinite, values.1.isFinite, values.0 <= values.1 else { throw NativeGlobalChargeFailure.invalidBinding }
                            lower = min(lower, values.0); upper = max(upper, values.1)
                        }
                        let value = try A.hull(lower: lower, upper: upper)
                        if let global = inventory.rawGlobal[raw] {
                            let index = anchor * n + global
                            charges[index] = try charges[index].adding(value)
                        }
                    }
                    // Anchor-local claims are deliberately not read or retained as domain identities.
                }
            }
            try checkpoint()
            closing = true
            try capture.close()
            return .init(retention: domainProof.0, rows: domainProof.1, lower: domainProof.2, upper: domainProof.3,
                lowerContext: domain.lowerContext, upperContext: domain.upperContext,
                usedPrecisionBits: domainProof.4, anchorPrecisionBits: anchorBits)
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
