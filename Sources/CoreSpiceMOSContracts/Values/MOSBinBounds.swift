/// Evaluated selection inputs; nil fields preserve omission rather than supplying defaults.
public struct MOSBinBounds: Sendable, Hashable {
    public let lengthMinimum: Double?
    public let lengthMaximum: Double?
    public let widthMinimum: Double?
    public let widthMaximum: Double?
    public init(lengthMinimum: Double?, lengthMaximum: Double?, widthMinimum: Double?, widthMaximum: Double?) {
        self.lengthMinimum = lengthMinimum; self.lengthMaximum = lengthMaximum
        self.widthMinimum = widthMinimum; self.widthMaximum = widthMaximum
    }
    /// Bits 0/1/2/3 identify missing LMIN/LMAX/WMIN/WMAX respectively.
    public var missingMask: UInt8 {
        (lengthMinimum == nil ? 1 : 0) | (lengthMaximum == nil ? 2 : 0) |
        (widthMinimum == nil ? 4 : 0) | (widthMaximum == nil ? 8 : 0)
    }
}
