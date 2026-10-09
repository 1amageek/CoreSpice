public enum MOSReleaseOrigin: Sendable, Hashable {
    case explicit(String)
    case defaulted(MOSInputProfile)
}
