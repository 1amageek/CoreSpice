import CircuiteFoundation

/// The previous semantic commitment; replay facts are always digested afresh.
public struct NativePrecisionConfigurationBinding: Sendable {
    public let legacyBaseDigest: ContentDigest
    public init(legacyBaseDigest: ContentDigest) { self.legacyBaseDigest = legacyBaseDigest }
}
