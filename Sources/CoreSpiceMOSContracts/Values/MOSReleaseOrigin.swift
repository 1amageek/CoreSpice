public enum MOSReleaseOrigin: Sendable, Hashable {
    case explicit(String)
    case explicitLevel(Int)
    case defaulted(MOSInputProfile)
}
