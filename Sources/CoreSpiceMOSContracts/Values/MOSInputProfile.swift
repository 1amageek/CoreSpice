/// Input interpretation is explicit and independent of numerical kernel admission.
public enum MOSInputProfile: String, Sendable, Hashable, CaseIterable {
    case coreStrictV1
    case pinnedNgspiceNormalV1
    public static let pinnedNgspiceCommit = "ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6"
}
