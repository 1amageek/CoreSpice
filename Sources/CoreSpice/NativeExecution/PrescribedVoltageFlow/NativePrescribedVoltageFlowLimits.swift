/// Explicit phase ceilings; every phase also uses the original preparation's shared ledger.
public struct NativePrescribedVoltageFlowLimits: Sendable {
    public struct Capacity: Sendable {
        public let maximumRetainedBytes: Int
        public let maximumWorkspaceBytes: Int
        public init(maximumRetainedBytes: Int, maximumWorkspaceBytes: Int) {
            self.maximumRetainedBytes = maximumRetainedBytes; self.maximumWorkspaceBytes = maximumWorkspaceBytes
        }
    }
    public let maximumNativeTerms: Int
    public let maximumTriplets: Int
    public let maximumPreconditionerNonzeros: Int
    public let maximumIntegerBits: Int
    public let precisionBits: UInt32
    public let values: Capacity
    public let reduction: Capacity
    public let chart: Capacity
    public let exact: Capacity
    public let root: Capacity
    public let evolution: Capacity
    public let result: Capacity
    public init(maximumNativeTerms: Int, maximumTriplets: Int, maximumPreconditionerNonzeros: Int,
        maximumIntegerBits: Int, precisionBits: UInt32, values: Capacity, reduction: Capacity,
        chart: Capacity, exact: Capacity, root: Capacity, evolution: Capacity, result: Capacity) {
        self.maximumNativeTerms = maximumNativeTerms; self.maximumTriplets = maximumTriplets
        self.maximumPreconditionerNonzeros = maximumPreconditionerNonzeros
        self.maximumIntegerBits = maximumIntegerBits; self.precisionBits = precisionBits
        self.values = values; self.reduction = reduction; self.chart = chart
        self.exact = exact; self.root = root; self.evolution = evolution; self.result = result
    }
}
