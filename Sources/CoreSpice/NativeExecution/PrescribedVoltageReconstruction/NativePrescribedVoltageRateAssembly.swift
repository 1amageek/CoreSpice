import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

internal enum NativePrescribedVoltageRateAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    static func reconstruct(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, leftReducedRates: [E], rightReducedRates: [E],
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageReconstructionLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageReconstruction.Payload {
        let source = try values.reconstructionPayload(record: record)
        guard let control = record.constitutiveBacking?.control else { throw NativePrescribedVoltageReconstructionFailure.wrongOwner }
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
        }
        try tick(0)
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        let n = values.dimension, k = source.plan.reducedCount, m = source.sources.count
        guard limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0,
              leftReducedRates.count == k, rightReducedRates.count == k else {
            throw NativePrescribedVoltageReconstructionFailure.invalidInput
        }
        guard source.captures.isEmpty || range != nil else { throw NativePrescribedVoltageReconstructionFailure.missingSmoothCapture }
        let retainedBytes = try A.add(MemoryLayout<NativePrescribedVoltageReconstruction.Payload>.stride,
            A.add(A.multiply(try A.add(A.multiply(n, 4), A.add(A.multiply(k, 2), A.multiply(m, 2))), MemoryLayout<E>.stride),
                A.multiply(source.captures.count, MemoryLayout<OSDISmoothRangeScope>.stride)))
        guard retainedBytes <= limits.maximumRetainedBytes else { throw NativePrescribedVoltageReconstructionFailure.capacityExceeded }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(retainedBytes))
        let scratchCells = try A.add(n, A.add(k, m))
        let scratchBytes = try A.add(A.multiply(scratchCells, MemoryLayout<E>.stride), A.multiply(n, MemoryLayout<Bool>.stride))
        guard scratchBytes <= limits.maximumWorkspaceBytes else { throw NativePrescribedVoltageReconstructionFailure.capacityExceeded }
        let scratch = try control.reserveStorage(byteCount: scratchBytes)
        defer { withExtendedLifetime(scratch) {} }
        try tick(A.add(A.add(scratchCells, n), A.add(A.multiply(n, 4), A.add(A.multiply(m, 2), source.captures.count))))
        let zero = try E(center: .zero)
        let zeroZ = [E](repeating: zero, count: k), zeroSource = [E](repeating: zero, count: m)
        let zeroTime = [E](repeating: zero, count: n)
        var selectedRows = [Bool](repeating: false, count: n)
        for index in 0..<m { try tick(); selectedRows[try source.plan.source(at: index).branchRow] = true }
        var slopesLeft: [E] = [], slopesRight: [E] = []
        slopesLeft.reserveCapacity(m); slopesRight.reserveCapacity(m)
        let domain = source.originalDomain
        let start = try CompensatedValue(high: domain.lowerContext.timeHigh, low: domain.lowerContext.timeLow)
        let end = try CompensatedValue(high: domain.upperContext.timeHigh, low: domain.upperContext.timeLow)
        for index in source.sources.indices {
            try tick()
            let input = source.sources[index]
            let jet = try source.laws[index].enclose(normalized: input.normalized, leftSlope: input.leftSlope,
                rightSlope: input.rightSlope, over: start.bounds.lower...end.bounds.upper, checkpoint: { try tick() })
            guard jet.voltage == source.voltages[index] else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
            slopesLeft.append(jet.leftSlope); slopesRight.append(jet.rightSlope)
        }
        let reduction = source.reduction, workspace = try reduction.makeWorkspace(plan: source.plan)
        // These are the two exact linear chain-rule components, not hypothetical physical zero rates.
        let stateLeftLift = try reduction.lift(workspace: workspace, reducedCoordinates: leftReducedRates, sourceValues: zeroSource)
        let stateRightLift = try reduction.lift(workspace: workspace, reducedCoordinates: rightReducedRates, sourceValues: zeroSource)
        let inputLeftLift = try reduction.lift(workspace: workspace, reducedCoordinates: zeroZ, sourceValues: slopesLeft)
        let inputRightLift = try reduction.lift(workspace: workspace, reducedCoordinates: zeroZ, sourceValues: slopesRight)
        var stateLeft = [E](repeating: zero, count: n), stateRight = stateLeft
        var inputLeft = stateLeft, inputRight = stateLeft
        for term in source.terms where term.plane == .charge {
            try tick(4)
            let coefficient = try E(center: .init(high: Double(bitPattern: term.coefficientBits)))
            stateLeft[term.row] = try stateLeft[term.row].adding(coefficient.multiplied(by: stateLeftLift.coordinate(at: term.column)))
            stateRight[term.row] = try stateRight[term.row].adding(coefficient.multiplied(by: stateRightLift.coordinate(at: term.column)))
            inputLeft[term.row] = try inputLeft[term.row].adding(coefficient.multiplied(by: inputLeftLift.coordinate(at: term.column)))
            inputRight[term.row] = try inputRight[term.row].adding(coefficient.multiplied(by: inputRightLift.coordinate(at: term.column)))
        }
        var scopes: [OSDISmoothRangeScope] = []
        scopes.reserveCapacity(source.captures.count)
        var foreign = 0
        for device in devices where device.instance.osdi != nil {
            try tick()
            guard let range, source.captures.indices.contains(foreign) else { throw NativePrescribedVoltageReconstructionFailure.missingSmoothCapture }
            let scope = try await NativePrescribedVoltageSourceRates.enclose(device: device,
                preparation: record.osdiPreparationRecords[foreign], original: source.captures[foreign], values: source,
                selectedRows: selectedRows, inputs: range, limits: limits, control: control,
                stateLeftLift: stateLeftLift, stateRightLift: stateRightLift, inputLeftLift: inputLeftLift, inputRightLift: inputRightLift,
                stateLeft: &stateLeft, stateRight: &stateRight, inputLeft: &inputLeft, inputRight: &inputRight,
                checkpoint: { try tick() })
            scopes.append(scope); foreign += 1
        }
        guard foreign == source.captures.count else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
        try tick(A.multiply(k, 2))
        let left = try reduction.apply(workspace: workspace, reducedCoordinates: source.reducedCoordinates,
            sourceValues: source.voltages, staticResidual: source.f, stateChargeRate: stateLeft,
            prescribedChargeRate: inputLeft, explicitTimeChargeRate: zeroTime)
        let right = try reduction.apply(workspace: workspace, reducedCoordinates: source.reducedCoordinates,
            sourceValues: source.voltages, staticResidual: source.f, stateChargeRate: stateRight,
            prescribedChargeRate: inputRight, explicitTimeChargeRate: zeroTime)
        func checkDomain(_ application: PrescribedVoltageReduction.Application,
            side: NativePrescribedVoltageReconstruction.Side) throws {
            for row in 0..<n {
                try tick()
                let bounds = try A.bounds(application.coordinate(at: row))
                guard A.ordered(domain.lower[row], bounds.0), A.ordered(bounds.1, domain.upper[row]) else {
                    throw NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(row: row, side: side)
                }
            }
        }
        try checkDomain(left, side: .left)
        try checkDomain(right, side: .right)
        try tick(0)
        return .init(values: values, leftRates: leftReducedRates, rightRates: rightReducedRates,
            leftSlopes: slopesLeft, rightSlopes: slopesRight, stateLeft: stateLeft, stateRight: stateRight,
            inputLeft: inputLeft, inputRight: inputRight, left: left, right: right, scopes: scopes, lease: lease)
    }
}
