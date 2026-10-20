import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

internal enum NativePrescribedVoltageChartAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    typealias T = NativePrescribedVoltageMassTriplet
    static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, algebraicRows: [Int], chargeParameters: [E],
        center: [CompensatedValue], inverse: SparseStructure, inverseValues: [Double],
        capture: OSDIConstitutiveCaptureInputs?, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageChartLimits, cancellation: CancellationToken) async throws -> NativePrescribedVoltageChart.Payload {
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
        let m = source.sources.count
        guard k > 0, b <= k, center.count == k, chargeParameters.count == k - b,
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
        var upperTriplets = source.terms.count, projectionBytes = 0
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
        let normWorkspaceBytes = try A.add(A.multiply(k - b, MemoryLayout<Double>.stride), MemoryLayout<[Double]>.stride)
        let workspaceBytes = try A.add(normWorkspaceBytes, A.add(A.multiply(A.multiply(capacity, 2), MemoryLayout<T>.stride),
            A.add(A.multiply(A.add(A.multiply(n, 2), A.multiply(k, 3)), MemoryLayout<Int>.stride),
                A.add(A.multiply(2, MemoryLayout<[T]>.stride), A.multiply(5, MemoryLayout<[Int]>.stride)))))
        let endpointBytes = try A.add(A.multiply(k, MemoryLayout<E>.stride), MemoryLayout<[E]>.stride)
        let containmentBytes = try A.add(endpointBytes, A.multiply(A.multiply(n, 4), MemoryLayout<E>.stride))
        let inputPhase = try A.add(MemoryLayout<[E]>.stride,
            A.multiply(A.add(A.multiply(n, 5), k), MemoryLayout<E>.stride))
        let queryPhase = try A.add(projectionBytes, A.multiply(A.multiply(n, 2), MemoryLayout<E>.stride))
        guard try A.add(workspaceBytes, max(containmentBytes, max(inputPhase, queryPhase))) <= limits.maximumWorkspaceBytes else {
            throw NativePrescribedVoltageChartFailure.capacityExceeded
        }
        let workspace = try control.reserveStorage(byteCount: workspaceBytes)
        defer { withExtendedLifetime(workspace) {} }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(limits.maximumRetainedBytes))
        var retained = NativeGlobalChargeArithmetic.Retained(control: control, lease: lease, limit: limits.maximumRetainedBytes)
        try retained.take(MemoryLayout<NativePrescribedVoltageChart.Payload>.stride)
        try retained.array(Int.self, count: k)
        try retained.array(E.self, count: A.add(k, chargeParameters.count))
        try retained.array(CompensatedValue.self, count: A.multiply(k, 3))
        try retained.array(Double.self, count: inverseValues.count)
        try retained.array(Int.self, count: A.add(inverse.rowPointers.count, inverse.columnIndices.count))
        try retained.array(NativeGlobalChargeKernel.LocalProof.self, count: foreign)
        try retained.array(OSDISmoothRangeScope.self, count: foreign)
        try retained.array(NativePrescribedVoltageChartSourceCharge.self, count: foreign)
        try retained.array(E.self, count: A.add(k, A.add(A.multiply(n, 5), A.multiply(m, 2))))
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
        try tick(k - b)
        var dynamicStaticSums = [Double](repeating: 0, count: k - b)
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
        var fullStatic = [E](repeating: zero, count: n)
        var inputChargeLeft = fullStatic, inputChargeRight = fullStatic
        var inputStaticLeft = fullStatic, inputStaticRight = fullStatic
        var leftSlopes: [E] = [], rightSlopes: [E] = []
        leftSlopes.reserveCapacity(m); rightSlopes.reserveCapacity(m)
        let originalDomain = source.originalDomain
        let start = try CompensatedValue(high: originalDomain.lowerContext.timeHigh, low: originalDomain.lowerContext.timeLow)
        let end = try CompensatedValue(high: originalDomain.upperContext.timeHigh, low: originalDomain.upperContext.timeLow)
        for index in 0..<m {
            try tick()
            let input = source.sources[index]
            let jet = try source.laws[index].enclose(normalized: input.normalized,
                leftSlope: input.leftSlope, rightSlope: input.rightSlope,
                over: start.bounds.lower...end.bounds.upper, checkpoint: { try tick() })
            guard jet.voltage == source.voltages[index] else { throw NativePrescribedVoltageChartFailure.invalidBinding }
            leftSlopes.append(jet.leftSlope); rightSlopes.append(jet.rightSlope)
        }
        let inputLeftLift: PrescribedVoltageReduction.Lift, inputRightLift: PrescribedVoltageReduction.Lift
        do {
            let zeroLease = try control.reserveStorage(byteCount: endpointBytes)
            defer { withExtendedLifetime(zeroLease) {} }
            try tick(k)
            let zeroZ = [E](repeating: zero, count: k)
            let inputWorkspace = try source.reduction.makeWorkspace(plan: source.plan)
            inputLeftLift = try source.reduction.lift(workspace: inputWorkspace, reducedCoordinates: zeroZ, sourceValues: leftSlopes)
            inputRightLift = try source.reduction.lift(workspace: inputWorkspace, reducedCoordinates: zeroZ, sourceValues: rightSlopes)
        }
        for term in source.terms {
            try tick()
            let coefficient = try E(center: .init(high: Double(bitPattern: term.coefficientBits)))
            let left = try coefficient.multiplied(by: inputLeftLift.coordinate(at: term.column))
            let right = try coefficient.multiplied(by: inputRightLift.coordinate(at: term.column))
            try tick(4)
            if term.plane == .charge {
                inputChargeLeft[term.row] = try inputChargeLeft[term.row].adding(left)
                inputChargeRight[term.row] = try inputChargeRight[term.row].adding(right)
            } else {
                inputStaticLeft[term.row] = try inputStaticLeft[term.row].adding(left)
                inputStaticRight[term.row] = try inputStaticRight[term.row].adding(right)
                let coordinate = try NativePrescribedVoltageChartSpatialData.enclosure(
                    lower: originalDomain.lower[term.column], upper: originalDomain.upper[term.column])
                fullStatic[term.row] = try fullStatic[term.row].adding(coefficient.multiplied(by: coordinate))
            }
        }
        for fact in source.unselected {
            try tick()
            guard case .dc(let voltage) = fact.waveform else { throw NativePrescribedVoltageChartFailure.invalidBinding }
            fullStatic[fact.branchRow] = try fullStatic[fact.branchRow].subtracting(E(center: .init(high: voltage)))
        }
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
        func boundDynamicStatic(row: Int, column: Int, coefficient: E) throws {
            try tick()
            guard (0..<n).contains(row), (0..<n).contains(column) else { throw NativePrescribedVoltageChartFailure.invalidBinding }
            let r = reduced[row], c = reduced[column]
            guard r >= 0, c >= 0, dynamicSlot[r] >= 0 else { return }
            try tick(3)
            let magnitude = coefficient.absoluteUpperBound
            guard magnitude.isFinite else { throw NumericalStateError.arithmeticOverflow }
            if magnitude == 0 { return }
            let slot = dynamicSlot[r]
            // Absolute contributions precede alias cancellation: this bounds the projected norm conservatively.
            let upper = (dynamicStaticSums[slot] + magnitude).nextUp
            guard upper.isFinite else { throw NumericalStateError.arithmeticOverflow }
            dynamicStaticSums[slot] = upper
        }
        func emit(row: Int, column: Int, coefficient: E, charge: Bool) throws {
            try tick()
            guard (0..<n).contains(row), (0..<n).contains(column) else { throw NativePrescribedVoltageChartFailure.invalidBinding }
            let r = reduced[row], c = reduced[column]
            if r < 0 || c < 0 { return }
            if charge != (dynamicSlot[r] >= 0) { return }
            try append(row: equation[r], column: c, value: coefficient)
        }
        for term in source.terms {
            try tick()
            let coefficient = try E(center: .init(high: Double(bitPattern: term.coefficientBits)))
            if term.plane == .staticResidual {
                try boundDynamicStatic(row: term.row, column: term.column, coefficient: coefficient)
            }
            try emit(row: term.row, column: term.column, coefficient: coefficient, charge: term.plane == .charge)
        }
        var smooth: [OSDISmoothRangeScope] = []; smooth.reserveCapacity(foreign)
        var sourceCharges: [NativePrescribedVoltageChartSourceCharge] = []; sourceCharges.reserveCapacity(foreign)
        foreignIndex = 0
        for device in devices where device.instance.osdi != nil {
            guard let range else { throw NativePrescribedVoltageChartFailure.missingSmoothCapture }
            let scope = try await NativePrescribedVoltageSpatialSource.withRange(device: device,
                preparation: record.osdiPreparationRecords[foreignIndex], original: identities[foreignIndex].retention,
                values: source, query: .original, inputs: range, maximumWorkspaceBytes: limits.maximumWorkspaceBytes,
                precisionBits: limits.precisionBits, control: control, checkpoint: { try tick() }) { view, inventory in
                let rawCount = inventory.rawGlobal.count, cells = try A.multiply(rawCount, rawCount)
                guard view.gLower.count == cells, view.gUpper.count == cells else { throw NativePrescribedVoltageChartFailure.invalidBinding }
                try retained.array(E.self, count: cells)
                var rawCharge = [E](repeating: zero, count: cells)
                for rawRow in 0..<rawCount {
                    try tick()
                    let staticValue = try A.hull(view.fLower[rawRow], view.fUpper[rawRow])
                    if let row = inventory.rawGlobal[rawRow] { fullStatic[row] = try fullStatic[row].adding(staticValue) }
                    for rawColumn in 0..<rawCount {
                        try tick()
                        let index = rawRow * rawCount + rawColumn
                        let g = try A.hull(view.gLower[index], view.gUpper[index])
                        let c = try A.hull(view.cLower[index], view.cUpper[index])
                        rawCharge[index] = c
                        guard let row = inventory.rawGlobal[rawRow], let column = inventory.rawGlobal[rawColumn] else { continue }
                        try boundDynamicStatic(row: row, column: column, coefficient: g)
                        try emit(row: row, column: column, coefficient: c, charge: true)
                        try emit(row: row, column: column, coefficient: g, charge: false)
                        if reduced[column] == -2 { continue } // Actual source READ exclusion; no invented current rate.
                        let left = try inputLeftLift.coordinate(at: column), right = try inputRightLift.coordinate(at: column)
                        try tick(8)
                        inputChargeLeft[row] = try inputChargeLeft[row].adding(c.multiplied(by: left))
                        inputChargeRight[row] = try inputChargeRight[row].adding(c.multiplied(by: right))
                        inputStaticLeft[row] = try inputStaticLeft[row].adding(g.multiplied(by: left))
                        inputStaticRight[row] = try inputStaticRight[row].adding(g.multiplied(by: right))
                    }
                }
                sourceCharges.append(.init(rawCount: rawCount, coefficients: rawCharge))
            }
            smooth.append(scope); foreignIndex += 1
        }
        var dynamicStaticNormUpperBound = 0.0
        for value in dynamicStaticSums { try tick(); dynamicStaticNormUpperBound = max(dynamicStaticNormUpperBound, value) }
        let nnz = try T.canonicalize(&entries, scratch: &scratch, count: count, checkpoint: { try tick() })
        try retained.array(Int.self, count: A.add(A.add(k, 1), nnz))
        try retained.array(E.self, count: nnz)
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
        try retained.array(E.self, count: k)
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
        var residual = [E](repeating: zero, count: k)
        for global in 0..<n {
            try tick()
            guard try centerSource.plan.reducedCoordinate(at: global) == source.plan.reducedCoordinate(at: global) else { throw NativePrescribedVoltageChartFailure.invalidBinding }
            let r = reduced[global]
            if r >= 0 { residual[equation[r]] = try residual[equation[r]].adding(dynamicSlot[r] >= 0 ? centerSource.q[global] : centerSource.f[global]) }
        }
        for index in chargeParameters.indices { try tick(); residual[index] = try residual[index].subtracting(chargeParameters[index]) }
        let root = try ValidatedParametricRoot.certify(lower: lower.span, upper: upper.span, center: center.span,
            centerResidual: residual.span, jacobian: jacobian, jacobianValues: coefficients.span,
            preconditioner: inverse, preconditionerValues: inverseValues.span, limits: limits.root, control: control)
        try tick(0)
        return .init(values: values, centerValues: centerValues, algebraic: algebraicRows, dynamic: dynamic,
            chargeParameters: chargeParameters, center: center, control: control,
            spatial: .init(dynamicStaticNormUpperBound: dynamicStaticNormUpperBound,
                staticResidual: fullStatic, leftSlopes: leftSlopes, rightSlopes: rightSlopes,
                inputChargeLeft: inputChargeLeft, inputChargeRight: inputChargeRight,
                inputStaticLeft: inputStaticLeft, inputStaticRight: inputStaticRight, sourceCharges: sourceCharges),
            checkedCoordinates: checkedCoordinates, checkedLower: lower, checkedUpper: upper, jacobian: jacobian, jacobianValues: coefficients,
            inverse: inverse, inverseValues: inverseValues, centerResidual: residual, identities: identities,
            smooth: smooth, root: root, lease: lease)
    }
}
