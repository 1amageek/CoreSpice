/// One dependency occurrence emitted by the SPICE grammar in lexical depth-first order.
public struct SPICESourceDependencyEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case include, externalLibrary }
    public let parentCaptureID: String?
    public let childCaptureID: String?
    public let location: SourceLocation?
    public let kind: Kind
    public let path: String
    public let selectedSection: String?
    public let ordinal: Int
    public let preprocessingContext: [String: String]

    public init(parentCaptureID: String?, childCaptureID: String?, location: SourceLocation?,
                kind: Kind, path: String, selectedSection: String?, ordinal: Int,
                preprocessingContext: [String: String]) {
        self.parentCaptureID = parentCaptureID
        self.childCaptureID = childCaptureID
        self.location = location
        self.kind = kind
        self.path = path
        self.selectedSection = selectedSection
        self.ordinal = ordinal
        self.preprocessingContext = preprocessingContext
    }
}
