import Foundation

/// Explicit caller ceilings for the precision CLI invocation and artifact boundary.
public struct CoreSpiceCLIPrecisionExecutionBudget: Codable, Sendable, Hashable {
    public let maximumNativeAllocationBytes: UInt64
    public let maximumLiveOwnedBytes: UInt64
    public let maximumTemporaryBytes: UInt64
    public let maximumHashedBytes: UInt64
    public let maximumEvidenceBytes: UInt64

    func validate() throws {
        guard [maximumNativeAllocationBytes, maximumLiveOwnedBytes, maximumTemporaryBytes,
               maximumHashedBytes, maximumEvidenceBytes].allSatisfy({ $0 > 0 && $0 <= UInt64(Int.max) }) else {
            throw CoreSpiceCLIOSDIError.invalidCatalog("Precision execution budgets must be positive representable byte ceilings")
        }
    }
}
