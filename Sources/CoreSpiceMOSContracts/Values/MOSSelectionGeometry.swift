public struct MOSSelectionGeometry: Sendable, Hashable {
    public let length: Double?
    public let width: Double?
    public let fingerDivisor: Double
    public init(length: Double?, width: Double?, fingerDivisor: Double) {
        self.length = length; self.width = width; self.fingerDivisor = fingerDivisor
    }
}
