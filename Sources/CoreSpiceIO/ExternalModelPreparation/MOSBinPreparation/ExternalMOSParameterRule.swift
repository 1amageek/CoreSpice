import CoreSpiceMOSContracts
import OSDIContracts

/// Caller-owned source spelling, foreign setter and normalization semantics.
public struct ExternalMOSParameterRule: Sendable {
    public enum Meaning: String, Sendable, Hashable {
        case ordinary, length, width, fingerCount, multiplicity
        case lengthMinimum, lengthMaximum, widthMinimum, widthMaximum
    }
    public let sourceNames: [String]
    public let scope: OSDIParameterScope
    public let providerName: String?
    public let scale: MOSParameterScale
    public let meaning: Meaning
    public let requiredValue: Double?
    public let nonnegative: Bool

    public init(sourceNames: [String], scope: OSDIParameterScope, providerName: String?,
                scale: MOSParameterScale, meaning: Meaning, requiredValue: Double? = nil, nonnegative: Bool = false) {
        self.sourceNames = sourceNames; self.scope = scope; self.providerName = providerName
        self.scale = scale; self.meaning = meaning; self.requiredValue = requiredValue; self.nonnegative = nonnegative
    }
}
