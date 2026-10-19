/// Logical payload/capacity counters; process RSS and heap allocation need separate measurement.
public struct SparseFactorizationStatistics: Sendable, Equatable {
    public let dimension: Int
    public let inputNonZeroCount: Int
    public let lowerNonZeroCount: Int
    public let upperNonZeroCount: Int
    public let factorCapacity: Int
    public let managedBytes: Int
    public let peakManagedBytes: Int
    public let workUnits: Int
    public let chargedWorkUnits: Int
    public let pivotInterchanges: Int
    public let structuralAnalyses: Int
    public let numericFactorizations: Int
    public let bufferAllocations: Int

    public var factorNonZeroCount: Int { lowerNonZeroCount + upperNonZeroCount }
}
