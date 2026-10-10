import CoreSpiceMOSContracts

/// Payload accounting excludes pre-existing resolution backing and allocator metadata.
struct MOSPreparationBudget {
    let limits: MOSPreparationLimits
    let control: any MOSPreparationControlling
    private(set) var retained: UInt64 = 0
    private(set) var temporary: UInt64 = 0
    private(set) var work: UInt64 = 0

    mutating func charge(_ units: UInt64 = 1) throws(MOSPreparationFailure) {
        try control.checkCancellation()
        work = try Self.add(work, units)
        guard work <= limits.maximumWorkUnits else { throw .workLimitExceeded }
        try control.chargeWork(units: units)
    }

    mutating func includeChargedWork(_ units: UInt64) throws(MOSPreparationFailure) {
        work = try Self.add(work, units)
        guard work <= limits.maximumWorkUnits else { throw .workLimitExceeded }
    }

    mutating func retain(_ bytes: UInt64) throws(MOSPreparationFailure) {
        retained = try Self.add(retained, bytes)
        guard retained <= limits.maximumRetainedBytes else { throw .capacityExceeded }
    }

    mutating func admitTemporary(_ bytes: UInt64) throws(MOSPreparationFailure) {
        temporary = max(temporary, bytes)
        guard temporary <= limits.maximumTemporaryBytes else { throw .capacityExceeded }
    }

    static func add(_ a: UInt64, _ b: UInt64) throws(MOSPreparationFailure) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw .arithmeticOverflow }
        return result
    }

    static func bytes<Element: ~Copyable>(_ count: Int, of: Element.Type) throws(MOSPreparationFailure) -> UInt64 {
        guard let count = UInt64(exactly: count) else { throw .arithmeticOverflow }
        let (result, overflow) = count.multipliedReportingOverflow(by: UInt64(MemoryLayout<Element>.stride))
        guard !overflow else { throw .arithmeticOverflow }
        return result
    }
}
