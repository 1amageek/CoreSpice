import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// Same-owner strong initial B/L plane, independent of root existence.
package struct NativePrescribedVoltageInitialStructure: Sendable {
    internal let preparation: NativeCircuitPreparationRecord
    internal let values: NativePrescribedVoltageValues
    internal let algebraic: [Int]
    internal let dynamic: [Int]
    internal let identities: [NativeGlobalChargeKernel.LocalProof]
    private let lease: any Sendable
    private init(preparation: NativeCircuitPreparationRecord, values: NativePrescribedVoltageValues,
        algebraic: [Int], dynamic: [Int], identities: [NativeGlobalChargeKernel.LocalProof], lease: any Sendable) {
        self.preparation = preparation; self.values = values; self.algebraic = algebraic
        self.dynamic = dynamic; self.identities = identities; self.lease = lease
    }
    internal static func validateRows(_ rows: [Int], count: Int, checkpoint: () throws -> Void) throws {
        for index in rows.indices {
            try checkpoint()
            guard (0..<count).contains(rows[index]), index == 0 || rows[index - 1] < rows[index] else {
                throw NativePrescribedVoltageChartFailure.invalidInput
            }
        }
    }
    internal static func fillAlgebraic(rows: [Int], algebraic: inout [Int], checkpoint: () throws -> Void) throws {
        for index in rows.indices { try checkpoint(); algebraic[rows[index]] = index }
    }
    internal static func fillDynamic(algebraic: [Int], count: Int, dynamicSlot: inout [Int],
        equation: inout [Int], dynamic: inout [Int], checkpoint: () throws -> Void) throws {
        let k = algebraic.count, b = count
        for row in 0..<k {
            try checkpoint()
            if algebraic[row] < 0 { dynamicSlot[row] = dynamic.count; dynamic.append(row); equation[row] = dynamicSlot[row] }
            else { equation[row] = k - b + algebraic[row] }
        }
    }
    internal static func fillProjection(source: NativePrescribedVoltageValues.Payload, algebraic: [Int],
        reduced: inout [Int], globalAlgebraic: inout [Int], checkpoint: () throws -> Void) throws {
        for row in reduced.indices {
            try checkpoint()
            if let value = try source.plan.reducedCoordinate(at: row) { reduced[row] = value; globalAlgebraic[row] = algebraic[value] }
        }
    }
    internal static func checkPlane(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        source: NativePrescribedVoltageValues.Payload, globalAlgebraic: [Int], zero: CompensatedEnclosure,
        entries: inout [NativePrescribedVoltageMassTriplet], scratch: inout [NativePrescribedVoltageMassTriplet],
        capture: OSDIConstitutiveCaptureInputs?, limits: NativePrescribedVoltageChartLimits,
        retained: inout NativeGlobalChargeArithmetic.Retained, control: any LinearSolverExecutionControlling,
        checkpoint: () throws -> Void) async throws -> [NativeGlobalChargeKernel.LocalProof] {
        typealias E = CompensatedEnclosure
        typealias T = NativePrescribedVoltageMassTriplet
        let capacity = entries.count, foreign = source.captures.count
        var count = 0
        func append(row: Int, column: Int, value: E) throws {
            try checkpoint()
            if value == zero { return }
            guard count < capacity else { throw NativePrescribedVoltageChartFailure.capacityExceeded }
            entries[count] = .init(row: row, column: column, value: value); count += 1
        }
        // A zero outward sum is an exact zero proof. A nonzero enclosure is never rounded to zero.
        for term in source.terms {
            try checkpoint()
            if term.plane == .charge, globalAlgebraic[term.row] >= 0 {
                try append(row: globalAlgebraic[term.row], column: term.column,
                    value: E(center: .init(high: Double(bitPattern: term.coefficientBits))))
            }
        }
        let nonzeroNative = try T.canonicalize(&entries, scratch: &scratch, count: count, checkpoint: { try checkpoint() })
        guard nonzeroNative == 0 else { throw NativePrescribedVoltageChartFailure.unprovedNullRow }
        var identities: [NativeGlobalChargeKernel.LocalProof] = []; identities.reserveCapacity(foreign)
        let exact = try ExactRowAlgebra(limits: limits.exact, control: control)
        var foreignIndex = 0
        for device in devices where device.instance.osdi != nil {
            try checkpoint()
            guard let capture else { throw NativePrescribedVoltageChartFailure.missingCaptureCapability }
            let identity = try await NativePrescribedVoltageChartSourceIdentity.check(device: device,
                preparation: record.osdiPreparationRecords[foreignIndex], values: source,
                original: source.captures[foreignIndex], globalAlgebraic: globalAlgebraic, inputs: capture,
                limits: limits, exact: exact, retained: &retained, control: control, checkpoint: { try checkpoint() })
            identities.append(identity); foreignIndex += 1
        }
        guard foreignIndex == foreign else { throw NativePrescribedVoltageChartFailure.invalidBinding }
        return identities
    }
    // Independent initial-plane preparation is qualified on the finite pinned fixtures.
    // Its package conditional-cover caller retains the original source and control;
    // this grants no global initial-set, outside-domain or history authority.
    internal static func prepare(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, algebraicRows: [Int], capture: OSDIConstitutiveCaptureInputs?,
        limits: NativePrescribedVoltageChartLimits, cancellation: CancellationToken) async throws -> Self {
        typealias A = NativePrescribedVoltageArithmetic
        typealias T = NativePrescribedVoltageMassTriplet
        let source = try values.reconstructionPayload(record: record)
        guard let control = record.constitutiveBacking?.control else { throw NativePrescribedVoltageChartFailure.wrongOwner }
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
        }
        try tick(0)
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        let domain = source.originalDomain, n = values.dimension, k = source.plan.reducedCount
        guard k > 0, algebraicRows.count <= k, limits.maximumTriplets >= 0,
              limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0,
              domain.lowerContext.timeHigh.bitPattern == domain.upperContext.timeHigh.bitPattern,
              domain.lowerContext.timeLow.bitPattern == domain.upperContext.timeLow.bitPattern else {
            throw NativePrescribedVoltageChartFailure.invalidInput
        }
        try validateRows(algebraicRows, count: k, checkpoint: { try tick() })
        let capacity = min(source.terms.count, limits.maximumTriplets)
        let ints = try A.add(A.multiply(n, 2), A.multiply(k, 3))
        let bytes = try A.add(A.multiply(A.multiply(capacity, 2), MemoryLayout<T>.stride),
            A.add(A.multiply(ints, MemoryLayout<Int>.stride),
                A.add(A.multiply(2, MemoryLayout<[T]>.stride), A.multiply(5, MemoryLayout<[Int]>.stride))))
        var projection = 0
        for prepared in record.osdiPreparationRecords {
            try tick()
            let raw = prepared.receipt.topology.nodes.count, active = prepared.receipt.topology.activeUnknownCount
            let common = try NativePrescribedVoltageSpatialSource.workspaceByteCount(activeCount: active)
            projection = max(projection, try A.add(common,
                A.add(A.multiply(raw, MemoryLayout<ExactRowAlgebra.Scalar>.stride), MemoryLayout<[ExactRowAlgebra.Scalar]>.stride)))
        }
        guard try A.add(bytes, projection) <= limits.maximumWorkspaceBytes else { throw NativePrescribedVoltageChartFailure.capacityExceeded }
        let workspace = try control.reserveStorage(byteCount: bytes)
        defer { withExtendedLifetime(workspace) {} }
        try tick(0)
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(limits.maximumRetainedBytes))
        try tick(0)
        var retained = NativeGlobalChargeArithmetic.Retained(control: control, lease: lease, limit: limits.maximumRetainedBytes)
        try retained.take(MemoryLayout<Self>.stride)
        try retained.array(Int.self, count: algebraicRows.count)
        try retained.array(Int.self, count: k - algebraicRows.count)
        try retained.array(NativeGlobalChargeKernel.LocalProof.self, count: source.captures.count)
        try tick(A.add(A.multiply(capacity, 2), ints))
        let zero = try CompensatedEnclosure(center: .zero), empty = T(row: 0, column: 0, value: zero)
        var entries = [T](repeating: empty, count: capacity), scratch = entries
        var algebraic = [Int](repeating: -1, count: k), dynamicSlot = algebraic, equation = algebraic
        try fillAlgebraic(rows: algebraicRows, algebraic: &algebraic, checkpoint: { try tick() })
        var dynamic: [Int] = []; dynamic.reserveCapacity(k - algebraicRows.count)
        try fillDynamic(algebraic: algebraic, count: algebraicRows.count, dynamicSlot: &dynamicSlot,
            equation: &equation, dynamic: &dynamic, checkpoint: { try tick() })
        var reduced = [Int](repeating: -1, count: n), globalAlgebraic = reduced
        try fillProjection(source: source, algebraic: algebraic, reduced: &reduced,
            globalAlgebraic: &globalAlgebraic, checkpoint: { try tick() })
        let identities = try await checkPlane(record: record, devices: devices, source: source,
            globalAlgebraic: globalAlgebraic, zero: zero, entries: &entries, scratch: &scratch, capture: capture,
            limits: limits, retained: &retained, control: control, checkpoint: { try tick() })
        try tick(algebraicRows.count)
        var ownedRows: [Int] = []; ownedRows.reserveCapacity(algebraicRows.count)
        for row in algebraicRows { try tick(); ownedRows.append(row) }
        try tick(0)
        return Self(preparation: record, values: values, algebraic: ownedRows, dynamic: dynamic,
            identities: identities, lease: lease)
    }
}
