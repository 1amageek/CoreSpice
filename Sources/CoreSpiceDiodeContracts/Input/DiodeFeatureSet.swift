public struct DiodeFeatureSet: Sendable, Hashable {
    private let bits: UInt8
    public static let none = Self()
    public init() { bits = 0 }
    public init(_ feature: DiodeFeature) { bits = 1 << feature.rawValue }
    public init(_ features: borrowing [DiodeFeature]) {
        var bits: UInt8 = 0
        for index in features.indices { bits |= 1 << features[index].rawValue }
        self.bits = bits
    }
    private init(bits: UInt8) { self.bits = bits }
    public func contains(_ feature: DiodeFeature) -> Bool { bits & (1 << feature.rawValue) != 0 }
    public func union(_ other: Self) -> Self { .init(bits: bits | other.bits) }
    public func requireSupport(by supported: Self) throws(DiodeSchemaFailure) {
        for index in 0..<5 {
            if let feature = DiodeFeature(rawValue: index), contains(feature), !supported.contains(feature) {
                throw .unsupportedFeature(feature)
            }
        }
    }
    func adding(_ feature: DiodeFeature) -> Self { .init(bits: bits | (1 << feature.rawValue)) }
}
