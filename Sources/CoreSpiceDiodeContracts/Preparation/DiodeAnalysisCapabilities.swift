public struct DiodeAnalysisCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let dc = Self(rawValue: 1 << 0)
    public static let ac = Self(rawValue: 1 << 1)
    public static let transient = Self(rawValue: 1 << 2)
    public static let noise = Self(rawValue: 1 << 3)
    public static let all: Self = [.dc, .ac, .transient, .noise]
}
