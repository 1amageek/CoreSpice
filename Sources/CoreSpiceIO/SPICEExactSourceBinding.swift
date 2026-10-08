import CircuiteFoundation

/// A caller-owned source key and its complete content/descriptor contract.
public struct SPICEExactSourceBinding: Sendable, Hashable {
    public let key: String
    public let reference: ArtifactReference
    public init(key: String, reference: ArtifactReference) {
        self.key = key
        self.reference = reference
    }
}
