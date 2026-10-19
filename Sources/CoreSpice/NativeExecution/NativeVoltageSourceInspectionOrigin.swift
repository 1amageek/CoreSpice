import CircuiteFoundation

/// Preparation identity, without a dynamic source-family or history assertion.
public enum NativeVoltageSourceInspectionOrigin: Sendable, Equatable {
    case circuit
    case spice(sourceInputIdentity: ContentDigest, sourceConfigurationIdentity: ContentDigest,
        nativeConfigurationIdentity: ContentDigest)
}
