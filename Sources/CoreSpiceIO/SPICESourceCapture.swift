import CircuiteFoundation
import CoreSpiceParser
import Foundation

/// Immutable bytes actually supplied to parsing, with content identity separate from location.
public struct SPICESourceCapture: Sendable {
    public let captureID: String
    public let artifactID: ArtifactID
    public let resolvedPath: String?
    public let bytes: Data
    public let document: SPICESourceDocument

    init(captureID: String, artifactID: ArtifactID, resolvedPath: String?, bytes: Data, text: String) {
        self.captureID = captureID
        self.artifactID = artifactID
        self.resolvedPath = resolvedPath
        self.bytes = bytes
        document = SPICESourceDocument(text: text, resolvedPath: resolvedPath, captureID: captureID)
    }
}
