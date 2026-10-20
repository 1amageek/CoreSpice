import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

internal enum NativePrescribedVoltageInitialRootAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    typealias T = NativePrescribedVoltageMassTriplet
    static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, algebraicRows: [Int], dynamicInitialCoordinates: [E],
        center: [CompensatedValue], inverse: SparseStructure, inverseValues: [Double],
        capture: OSDIConstitutiveCaptureInputs?, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageChartLimits, cancellation: CancellationToken) async throws -> NativePrescribedVoltageInitialRoot.Payload {
        let source: NativePrescribedVoltageValues.Payload
        do { source = try values.reconstructionPayload(record: record) }
        catch NativePrescribedVoltageReconstructionFailure.wrongOwner { throw NativePrescribedVoltageChartFailure.wrongOwner }
        guard let control = record.constitutiveBacking?.control else { throw NativePrescribedVoltageChartFailure.wrongOwner }
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
        }
        try tick(0)
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        let n = values.dimension, k = source.plan.reducedCount, b = algebraicRows.count, foreign = source.captures.count
        let initial = source.originalDomain
        guard initial.lowerContext.timeHigh.bitPattern == initial.upperContext.timeHigh.bitPattern,
              initial.lowerContext.timeLow.bitPattern == initial.upperContext.timeLow.bitPattern else {
            throw NativePrescribedVoltageChartFailure.invalidBinding
        }
        guard k > 0, b <= k, center.count == k, dynamicInitialCoordinates.count == k - b,
              inverse.dimension == k, limits.maximumTriplets >= 0,
              limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0 else {
            throw NativePrescribedVoltageChartFailure.invalidInput
        }
        if foreign > 0 {
            guard capture != nil else { throw NativePrescribedVoltageChartFailure.missingCaptureCapability }
            guard range != nil else { throw NativePrescribedVoltageChartFailure.missingSmoothCapture }
        }
        for index in algebraicRows.indices {
            try tick()
            guard (0..<k).contains(algebraicRows[index]), index == 0 || algebraicRows[index - 1] < algebraicRows[index] else {
                throw NativePrescribedVoltageChartFailure.invalidInput
            }
        }
        for row in 0..<k {
            try tick()
            let bounds = try A.bounds(source.reducedCoordinates[row])
            guard A.ordered(bounds.0, center[row]), A.ordered(center[row], bounds.1) else { throw NativePrescribedVoltageChartFailure.invalidInput }
        }
        let zero = try E(center: .zero)
        var upperTriplets = try A.add(source.terms.count, k - b), projectionBytes = 0
        for prepared in record.osdiPreparationRecords {
            try tick()
            let raw = prepared.receipt.topology.nodes.count, active = prepared.receipt.topology.activeUnknownCount
            upperTriplets = try A.add(upperTriplets, A.multiply(raw, raw))
            let common = try NativePrescribedVoltageSpatialSource.workspaceByteCount(activeCount: active)
            let identity = try A.add(common, A.add(A.multiply(raw, MemoryLayout<ExactRowAlgebra.Scalar>.stride), MemoryLayout<[ExactRowAlgebra.Scalar]>.stride))
            projectionBytes = max(projectionBytes, identity)
        }
        let capacity = min(upperTriplets, limits.maximumTriplets)
        // Two bounded sort buffers and fixed global/reduced maps coexist with retained outputs.
        let workspaceBytes = try A.add(A.multiply(A.multiply(capacity, 2), MemoryLayout<T>.stride),
            A.add(A.multiply(A.add(A.multiply(n, 2), A.multiply(k, 3)), MemoryLayout<Int>.stride),
                A.add(A.multiply(2, MemoryLayout<[T]>.stride), A.multiply(5, MemoryLayout<[Int]>.stride))))
        let endpointBytes = try A.add(A.multiply(k, MemoryLayout<E>.stride), MemoryLayout<[E]>.stride)
        let containmentBytes = try A.add(endpointBytes, A.multiply(A.multiply(n, 4), MemoryLayout<E>.stride))
        guard try A.add(workspaceBytes, max(containmentBytes, projectionBytes)) <= limits.maximumWorkspaceBytes else {
            throw NativePrescribedVoltageChartFailure.capacityExceeded
        }
        let workspace = try control.reserveStorage(byteCount: workspaceBytes)
        defer { withExtendedLifetime(workspace) {} }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(limits.maximumRetainedBytes))
        var retained = NativeGlobalChargeArithmetic.Retained(control: control, lease: lease, limit: limits.maximumRetainedBytes)
        try retained.take(MemoryLayout<NativePrescribedVoltageInitialRoot.Payload>.stride)
        try retained.array(Int.self, count: k)
        // Checked-Z coordinates, initial parameters, derived charges, center coordinates and H0 coexist.
        try retained.array(E.self, count: A.add(A.multiply(k, 3), A.multiply(k - b, 2)))
        try retained.array(CompensatedValue.self, count: A.multiply(k, 3))
        try retained.array(Double.self, count: inverseValues.count)
        try retained.array(Int.self, count: A.add(inverse.rowPointers.count, inverse.columnIndices.count))
        try retained.array(NativeGlobalChargeKernel.LocalProof.self, count: foreign)
        try retained.array(OSDISmoothRangeScope.self, count: foreign)
        try tick(A.add(A.multiply(capacity, 2), A.add(A.multiply(n, 2), A.multiply(k, 3))))
        let empty = T(row: 0, column: 0, value: zero)
        var entries = [T](repeating: empty, count: capacity), scratch = entries
        var algebraic = [Int](repeating: -1, count: k), dynamicSlot = algebraic, equation = algebraic
        for index in algebraicRows.indices { try tick(); algebraic[algebraicRows[index]] = index }
        var dynamic: [Int] = []; dynamic.reserveCapacity(k - b)
        for row in 0..<k {
            try tick()
            if algebraic[row] < 0 { dynamicSlot[row] = dynamic.count; dynamic.append(row); equation[row] = dynamicSlot[row] }
            else { equation[row] = k - b + algebraic[row] }
        }
        var reduced = [Int](repeating: -1, count: n), globalAlgebraic = reduced
        for row in 0..<n {
            try tick()
            if let value = try source.plan.reducedCoordinate(at: row) { reduced[row] = value; globalAlgebraic[row] = algebraic[value] }
        }
        // The lower check uses these represented endpoints, not the unexpanded CE proposal.
        var lower: [CompensatedValue] = [], upper = lower
        lower.reserveCapacity(k); upper.reserveCapacity(k)
        for row in 0..<k {
            try tick(); let bounds = try A.bounds(source.reducedCoordinates[row])
            lower.append(bounds.0); upper.append(bounds.1)
        }
        for index in 0..<source.plan.sourceCount {
            try tick(); reduced[try source.plan.source(at: index).branchRow] = -2
        }
        let checkedCoordinates: [E]
        do {
            try tick(k)
            var expanded: [E] = []; expanded.reserveCapacity(k)
            for row in 0..<k {
                try tick()
                if source.reducedCoordinates[row].radius == 0 { expanded.append(source.reducedCoordinates[row]) }
                else {
                    // A.bounds for nonzero radius returns outward finite Double endpoints (low=0).
                    expanded.append(try A.hull(lower[row].high, upper[row].high))
                }
            }
            let reductionWorkspace = try source.reduction.makeWorkspace(plan: source.plan)
            let lift = try source.reduction.lift(workspace: reductionWorkspace, reducedCoordinates: expanded,
                sourceValues: source.voltages)
            for row in 0..<n {
                try tick()
                if reduced[row] == -2 { continue } // Keep the original formal current section.
                let bounds = try A.bounds(lift.coordinate(at: row))
                guard A.ordered(source.originalDomain.lower[row], bounds.0),
                      A.ordered(bounds.1, source.originalDomain.upper[row]) else {
                    throw NativePrescribedVoltageFailure.outsideOriginalDomain(row: row)
                }
            }
            checkedCoordinates = expanded
        }
        // The expanded coordinates persist; containment workspace/lift end before any source query.
        var count = 0
        func append(row: Int, column: Int, value: E) throws {
            try tick()
            if value == zero { return }
            guard count < capacity else { throw NativePrescribedVoltageChartFailure.capacityExceeded }
            entries[count] = .init(row: row, column: column, value: value); count += 1
        }
        // A zero outward sum is an exact zero proof. A nonzero enclosure is never rounded to zero.
        for term in source.terms {
            try tick()
            if term.plane == .charge, globalAlgebraic[term.row] >= 0 {
                try append(row: globalAlgebraic[term.row], column: term.column,
                    value: E(center: .init(high: Double(bitPattern: term.coefficientBits))))
            }
        }
        let nonzeroNative = try T.canonicalize(&entries, scratch: &scratch, count: count, checkpoint: { try tick() })
        guard nonzeroNative == 0 else { throw NativePrescribedVoltageChartFailure.unprovedNullRow }
        var identities: [NativeGlobalChargeKernel.LocalProof] = []; identities.reserveCapacity(foreign)
        let exact = try ExactRowAlgebra(limits: limits.exact, control: control)
        var foreignIndex = 0
        for device in devices where device.instance.osdi != nil {
            try tick()
            guard let capture else { throw NativePrescribedVoltageChartFailure.missingCaptureCapability }
            let identity = try await NativePrescribedVoltageChartSourceIdentity.check(device: device,
                preparation: record.osdiPreparationRecords[foreignIndex], values: source,
                original: source.captures[foreignIndex], globalAlgebraic: globalAlgebraic, inputs: capture,
                limits: limits, exact: exact, retained: &retained, control: control, checkpoint: { try tick() })
            identities.append(identity); foreignIndex += 1
        }
        guard foreignIndex == foreign else { throw NativePrescribedVoltageChartFailure.invalidBinding }
        count = 0
        let one = try E(center: .init(high: 1))
        for index in dynamic.indices { try append(row: index, column: dynamic[index], value: one) }
        func emitStatic(row: Int, column: Int, coefficient: E) throws {
            try tick()
            guard (0..<n).contains(row), (0..<n).contains(column) else {
                throw NativePrescribedVoltageChartFailure.invalidBinding
            }
            let r = reduced[row], c = reduced[column]
            guard r >= 0, c >= 0, algebraic[r] >= 0 else { return }
            try append(row: equation[r], column: c, value: coefficient)
        }
        for term in source.terms {
            try tick()
            if term.plane == .staticResidual {
                try emitStatic(row: term.row, column: term.column,
                    coefficient: E(center: .init(high: Double(bitPattern: term.coefficientBits))))
            }
        }
        var smooth: [OSDISmoothRangeScope] = []; smooth.reserveCapacity(foreign)
        foreignIndex = 0
        for device in devices where device.instance.osdi != nil {
            try tick()
            guard let range else { throw NativePrescribedVoltageChartFailure.missingSmoothCapture }
            let scope = try await NativePrescribedVoltageSpatialSource.withRange(device: device,
                preparation: record.osdiPreparationRecords[foreignIndex], original: identities[foreignIndex].retention,
                values: source, query: .original, inputs: range, maximumWorkspaceBytes: limits.maximumWorkspaceBytes,
                precisionBits: limits.precisionBits, control: control, checkpoint: { try tick() }) { view, inventory in
                let rawCount = inventory.rawGlobal.count, cells = try A.multiply(rawCount, rawCount)
                guard view.gLower.count == cells, view.gUpper.count == cells else {
                    throw NativePrescribedVoltageChartFailure.invalidBinding
                }
                for rawRow in 0..<rawCount {
                    for rawColumn in 0..<rawCount {
                        try tick()
                        let index = rawRow * rawCount + rawColumn
                        let g = try A.hull(view.gLower[index], view.gUpper[index])
                        guard let row = inventory.rawGlobal[rawRow], let column = inventory.rawGlobal[rawColumn] else { continue }
                        try emitStatic(row: row, column: column, coefficient: g)
                    }
                }
            }
            smooth.append(scope); foreignIndex += 1
        }
        guard foreignIndex == foreign else { throw NativePrescribedVoltageChartFailure.invalidBinding }
        let nnz = try T.canonicalize(&entries, scratch: &scratch, count: count, checkpoint: { try tick() })
        try retained.array(Int.self, count: A.add(A.add(k, 1), nnz))
        try retained.array(E.self, count: nnz)
        try tick(A.add(A.add(k, 1), A.multiply(nnz, 2)))
        var rows = [Int](repeating: 0, count: try A.add(k, 1)), columns = [Int](repeating: 0, count: nnz)
        var coefficients = [E](repeating: zero, count: nnz)
        for index in 0..<nnz {
            try tick(); rows[entries[index].row + 1] += 1
            columns[index] = entries[index].column; coefficients[index] = entries[index].value
        }
        for row in 0..<k { try tick(); rows[row + 1] = try A.add(rows[row + 1], rows[row]) }
        try tick(A.add(k, nnz))
        let jacobian = try SparseStructure(dimension: k, rowPointers: rows, columnIndices: columns)
        // Exact z center only; source phi/U/time remain their entire original parameter box.
        try tick(k)
        var centerCoordinates: [E] = []; centerCoordinates.reserveCapacity(k)
        for value in center { try tick(); centerCoordinates.append(try E(center: value)) }
        let centerValues = try await NativePrescribedVoltageValues.enclose(record: record, devices: devices,
            originalDomain: source.originalDomain, sources: source.sources, reducedCoordinates: centerCoordinates,
            capture: capture, limits: limits.values, cancellation: cancellation)
        let centerSource = try centerValues.reconstructionPayload(record: record)
        guard centerSource.captures.count == foreign, centerSource.voltages == source.voltages else { throw NativePrescribedVoltageChartFailure.invalidBinding }
        for index in 0..<foreign {
            try tick()
            let first = identities[index].retention, actual = centerSource.captures[index]
            guard actual.source == first.source, actual.workerReference == first.workerReference,
                  actual.numericProfile == first.numericProfile, actual.options == first.options,
                  actual.coverLimits == first.coverLimits, actual.identityLimits == first.identityLimits else {
                throw NativePrescribedVoltageChartFailure.invalidBinding
            }
        }
        try tick(k)
        var residual = [E](repeating: zero, count: k)
        for index in dynamic.indices {
            try tick()
            residual[index] = try E(center: center[dynamic[index]]).subtracting(dynamicInitialCoordinates[index])
        }
        for global in 0..<n {
            try tick()
            guard try centerSource.plan.reducedCoordinate(at: global) == source.plan.reducedCoordinate(at: global) else {
                throw NativePrescribedVoltageChartFailure.invalidBinding
            }
            let r = reduced[global]
            if r >= 0, algebraic[r] >= 0 {
                residual[equation[r]] = try residual[equation[r]].adding(centerSource.f[global])
            }
        }
        let root = try ValidatedParametricRoot.certify(lower: lower.span, upper: upper.span, center: center.span,
            centerResidual: residual.span, jacobian: jacobian, jacobianValues: coefficients.span,
            preconditioner: inverse, preconditionerValues: inverseValues.span, limits: limits.root, control: control)
        try tick(0)
        // Only a successful root permits the actual Q query. Its whole checked Z is
        // retained, rather than the narrower CE proposal or an unproved image clipping.
        let checkedQValues = try await NativePrescribedVoltageValues.enclose(record: record, devices: devices,
            originalDomain: source.originalDomain, sources: source.sources, reducedCoordinates: checkedCoordinates,
            capture: capture, limits: limits.values, cancellation: cancellation)
        let checkedQ = try checkedQValues.reconstructionPayload(record: record)
        guard checkedQ.captures.count == foreign, checkedQ.voltages == source.voltages,
              checkedQ.originalDomain.lowerContext == source.originalDomain.lowerContext,
              checkedQ.originalDomain.upperContext == source.originalDomain.upperContext else {
            throw NativePrescribedVoltageChartFailure.invalidBinding
        }
        for index in 0..<foreign {
            try tick()
            let first = identities[index].retention, actual = checkedQ.captures[index]
            guard actual.source == first.source, actual.workerReference == first.workerReference,
                  actual.numericProfile == first.numericProfile, actual.options == first.options,
                  actual.coverLimits == first.coverLimits, actual.identityLimits == first.identityLimits else {
                throw NativePrescribedVoltageChartFailure.invalidBinding
            }
        }
        try tick(k - b)
        var initialCharge = [E](repeating: zero, count: k - b)
        for global in 0..<n {
            try tick()
            guard try checkedQ.plan.reducedCoordinate(at: global) == source.plan.reducedCoordinate(at: global) else {
                throw NativePrescribedVoltageChartFailure.invalidBinding
            }
            let r = reduced[global]
            if r >= 0, dynamicSlot[r] >= 0 {
                let slot = dynamicSlot[r]
                initialCharge[slot] = try initialCharge[slot].adding(checkedQ.q[global])
            }
        }
        try tick(0)
        return .init(values: values, centerValues: centerValues, checkedQValues: checkedQValues,
            algebraic: algebraicRows, dynamic: dynamic, dynamicInitialCoordinates: dynamicInitialCoordinates,
            initialCharge: initialCharge, center: center, control: control,
            checkedCoordinates: checkedCoordinates, checkedLower: lower, checkedUpper: upper,
            jacobian: jacobian, jacobianValues: coefficients, inverse: inverse, inverseValues: inverseValues,
            centerResidual: residual, identities: identities, smooth: smooth, root: root, lease: lease)
    }
}
