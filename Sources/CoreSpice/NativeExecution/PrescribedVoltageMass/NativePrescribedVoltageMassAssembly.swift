import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

internal enum NativePrescribedVoltageMassAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    typealias T = NativePrescribedVoltageMassTriplet
    static func workspaceByteCount(capacity: Int, dimension: Int, reducedCount: Int,
        sourceCount: Int, projectionBytes: Int) throws -> (fixed: Int, peak: Int) {
        let cells = try A.add(reducedCount, A.multiply(sourceCount, 2))
        let headers = try A.add(A.multiply(2, MemoryLayout<[T]>.stride),
            A.add(MemoryLayout<[Int]>.stride, A.multiply(3, MemoryLayout<[E]>.stride)))
        let fixed = try A.add(headers, A.add(A.multiply(capacity, A.multiply(2, MemoryLayout<T>.stride)),
            A.add(A.multiply(dimension, MemoryLayout<Int>.stride), A.multiply(cells, MemoryLayout<E>.stride))))
        let peak = try A.add(fixed, A.add(A.multiply(A.multiply(dimension, 5), MemoryLayout<E>.stride), projectionBytes))
        return (fixed, peak)
    }
    static func assemble(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageMassLimits, cancellation: CancellationToken) async throws -> NativePrescribedVoltageMass.Payload {
        let source: NativePrescribedVoltageValues.Payload
        do { source = try values.reconstructionPayload(record: record) }
        catch NativePrescribedVoltageReconstructionFailure.wrongOwner { throw NativePrescribedVoltageMassFailure.wrongOwner }
        guard let control = record.constitutiveBacking?.control else { throw NativePrescribedVoltageMassFailure.wrongOwner }
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
        }
        try tick(0)
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        guard limits.maximumTriplets >= 0, limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0 else {
            throw NativePrescribedVoltageMassFailure.invalidInput
        }
        guard source.captures.isEmpty || range != nil else { throw NativePrescribedVoltageMassFailure.missingSmoothCapture }
        let n = values.dimension, k = source.plan.reducedCount, m = source.sources.count
        var upperTriplets = 0, projectionBytes = 0
        for term in source.terms {
            try tick()
            if term.plane == .charge { upperTriplets = try A.add(upperTriplets, 1) }
        }
        for prepared in record.osdiPreparationRecords {
            try tick()
            let topology = prepared.receipt.topology
            upperTriplets = try A.add(upperTriplets, A.multiply(topology.nodes.count, topology.nodes.count))
            projectionBytes = max(projectionBytes, try NativePrescribedVoltageSpatialSource.workspaceByteCount(activeCount: topology.activeUnknownCount))
        }
        let capacity = min(upperTriplets, limits.maximumTriplets)
        // Triplets/sort/map remain live with reduction workspace, two E lifts,
        // zero coordinates, slopes and one source projection. The original global
        // accountant also owns all foreign helper/inventory/output coexistence.
        let ownCells = try A.add(k, A.multiply(m, 2))
        let capacities = try workspaceByteCount(capacity: capacity, dimension: n, reducedCount: k,
            sourceCount: m, projectionBytes: projectionBytes)
        let fixedBytes = capacities.fixed, peakWorkspace = capacities.peak
        guard peakWorkspace <= limits.maximumWorkspaceBytes else { throw NativePrescribedVoltageMassFailure.capacityExceeded }
        let baseBytes = try A.add(MemoryLayout<NativePrescribedVoltageMass.Payload>.stride,
            A.add(A.multiply(A.multiply(k, 2), MemoryLayout<E>.stride),
                A.multiply(source.captures.count, MemoryLayout<OSDISmoothRangeScope>.stride)))
        guard baseBytes <= limits.maximumRetainedBytes else { throw NativePrescribedVoltageMassFailure.capacityExceeded }
        let workspaceLease = try control.reserveStorage(byteCount: fixedBytes)
        defer { withExtendedLifetime(workspaceLease) {} }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(baseBytes))
        try tick(A.add(A.multiply(capacity, 2), A.add(n, A.add(ownCells, A.add(A.multiply(k, 2), source.captures.count)))))
        let zero = try E(center: .zero), empty = T(row: 0, column: 0, value: zero)
        var entries = [T](repeating: empty, count: capacity), scratch = entries
        var map = [Int](repeating: -1, count: n)
        for row in 0..<n { try tick(); map[row] = try source.plan.reducedCoordinate(at: row) ?? -1 }
        for index in 0..<m { try tick(); map[try source.plan.source(at: index).branchRow] = -2 }
        var left = [E](repeating: zero, count: k), right = left
        for row in 0..<n {
            try tick()
            if map[row] >= 0 { left[map[row]] = try left[map[row]].adding(source.f[row]) }
        }
        // F0 is the same slab enclosure on both sides, with independently accumulated source slopes.
        try tick(k)
        for row in 0..<k { right[row] = left[row] }
        let zeroZ = [E](repeating: zero, count: k)
        var slopesLeft: [E] = [], slopesRight: [E] = []
        slopesLeft.reserveCapacity(m); slopesRight.reserveCapacity(m)
        let d = source.originalDomain
        let start = try CompensatedValue(high: d.lowerContext.timeHigh, low: d.lowerContext.timeLow)
        let end = try CompensatedValue(high: d.upperContext.timeHigh, low: d.upperContext.timeLow)
        for index in 0..<m {
            try tick()
            let input = source.sources[index]
            let jet = try source.laws[index].enclose(normalized: input.normalized, leftSlope: input.leftSlope,
                rightSlope: input.rightSlope, over: start.bounds.lower...end.bounds.upper, checkpoint: { try tick() })
            guard jet.voltage == source.voltages[index] else { throw NativePrescribedVoltageMassFailure.invalidBinding }
            slopesLeft.append(jet.leftSlope); slopesRight.append(jet.rightSlope)
        }
        let workspace = try source.reduction.makeWorkspace(plan: source.plan)
        let leftLift = try source.reduction.lift(workspace: workspace, reducedCoordinates: zeroZ, sourceValues: slopesLeft)
        let rightLift = try source.reduction.lift(workspace: workspace, reducedCoordinates: zeroZ, sourceValues: slopesRight)
        var count = 0
        func emit(row: Int, column: Int, coefficient: E) throws {
            try tick()
            guard (0..<n).contains(row), (0..<n).contains(column) else { throw NativePrescribedVoltageMassFailure.invalidBinding }
            guard map[row] >= 0, map[column] != -2, coefficient != zero else { return }
            let reducedRow = map[row]
            try tick(2)
            left[reducedRow] = try left[reducedRow].adding(coefficient.multiplied(by: leftLift.coordinate(at: column)))
            right[reducedRow] = try right[reducedRow].adding(coefficient.multiplied(by: rightLift.coordinate(at: column)))
            if map[column] >= 0 {
                guard count < capacity else { throw NativePrescribedVoltageMassFailure.capacityExceeded }
                try tick()
                entries[count] = T(row: reducedRow, column: map[column], value: coefficient); count += 1
            }
        }
        for term in source.terms where term.plane == .charge {
            try emit(row: term.row, column: term.column, coefficient: E(center: .init(high: Double(bitPattern: term.coefficientBits))))
        }
        var scopes: [OSDISmoothRangeScope] = []
        scopes.reserveCapacity(source.captures.count)
        var foreign = 0
        for device in devices where device.instance.osdi != nil {
            try tick()
            guard let range, source.captures.indices.contains(foreign) else { throw NativePrescribedVoltageMassFailure.missingSmoothCapture }
            let scope = try await NativePrescribedVoltageSpatialSource.withRange(device: device,
                preparation: record.osdiPreparationRecords[foreign], original: source.captures[foreign], values: source,
                query: .original, inputs: range, maximumWorkspaceBytes: projectionBytes,
                precisionBits: limits.precisionBits, control: control, checkpoint: { try tick() }) { view, inventory in
                    let rawCount = inventory.rawGlobal.count
                    for rawRow in 0..<rawCount {
                        for rawColumn in 0..<rawCount {
                            try tick()
                            let index = try A.add(A.multiply(rawRow, rawCount), rawColumn)
                            let coefficient = try A.hull(view.cLower[index], view.cUpper[index])
                            if let row = inventory.rawGlobal[rawRow], let column = inventory.rawGlobal[rawColumn] {
                                try emit(row: row, column: column, coefficient: coefficient)
                            }
                        }
                    }
                }
            scopes.append(scope); foreign += 1
        }
        guard foreign == source.captures.count else { throw NativePrescribedVoltageMassFailure.invalidBinding }
        let nonzeros = try T.canonicalize(&entries, scratch: &scratch, count: count, checkpoint: { try tick() })
        let rows = try A.add(k, 1)
        let matrixBytes = try A.add(A.multiply(rows, MemoryLayout<Int>.stride),
            A.multiply(nonzeros, A.add(MemoryLayout<Int>.stride, MemoryLayout<E>.stride)))
        guard try A.add(baseBytes, matrixBytes) <= limits.maximumRetainedBytes else { throw NativePrescribedVoltageMassFailure.capacityExceeded }
        let matrixLease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(matrixBytes))
        try tick(A.add(rows, A.multiply(nonzeros, 2)))
        var rowPointers = [Int](repeating: 0, count: rows), columns = [Int](repeating: 0, count: nonzeros)
        var coefficients = [E](repeating: zero, count: nonzeros)
        for index in 0..<nonzeros {
            try tick()
            let item = entries[index]
            rowPointers[item.row + 1] += 1; columns[index] = item.column; coefficients[index] = item.value
        }
        for row in 0..<k { try tick(); rowPointers[row + 1] = try A.add(rowPointers[row + 1], rowPointers[row]) }
        // The checked existing constructor performs a bounded O(k+nnz) validation;
        // precharge that scan and check cancellation on both sides of the call.
        try tick(A.add(rows, nonzeros))
        let pattern = try SparseStructure(dimension: k, rowPointers: rowPointers, columnIndices: columns)
        try tick(0)
        return .init(values: values, pattern: pattern, coefficients: coefficients,
            leftDrift: left, rightDrift: right, scopes: scopes, control: control, lease: lease, matrixLease: matrixLease)
    }
}
