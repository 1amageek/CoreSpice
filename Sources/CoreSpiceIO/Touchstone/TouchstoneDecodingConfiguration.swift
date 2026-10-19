/// Diagnostic metadata and an explicit port-count hint for legacy S data.
public struct TouchstoneDecodingConfiguration: Sendable {
    public var sourceName: String?
    public var portCountHint: Int?
    public var fileExtensionHint: String?

    public init(sourceName: String? = nil, portCountHint: Int? = nil, fileExtensionHint: String? = nil) {
        self.sourceName = sourceName
        self.portCountHint = portCountHint
        self.fileExtensionHint = fileExtensionHint
    }
}
