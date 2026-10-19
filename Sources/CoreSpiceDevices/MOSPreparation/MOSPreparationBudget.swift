import CoreSpiceMOSContracts

/// Payload accounting excludes pre-existing resolution backing and allocator metadata.
struct MOSPreparationBudget {
    let limits: MOSPreparationLimits
    let control: any MOSPreparationControlling
    private(set) var retained: UInt64 = 0
    let temporary: UInt64 = 0 // Classic preparation owns no projected temporary payload.
    private(set) var work: UInt64 = 0

    mutating func charge(_ units: UInt64 = 1) throws(MOSPreparationFailure) {
        try control.checkCancellation()
        work = try Self.add(work, units)
        guard work <= limits.maximumWorkUnits else { throw .workLimitExceeded }
        try control.chargeWork(units: units)
    }

    mutating func retain(_ bytes: UInt64) throws(MOSPreparationFailure) {
        retained = try Self.add(retained, bytes)
        guard retained <= limits.maximumRetainedBytes else { throw .capacityExceeded }
    }

    static func add(_ a: UInt64, _ b: UInt64) throws(MOSPreparationFailure) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw .arithmeticOverflow }
        return result
    }

}
