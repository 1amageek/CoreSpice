import CircuiteFoundation

public enum CoreSpiceArtifactLocatorError: Error, Sendable, Equatable {
    case missingLocation(ArtifactID)
    case descriptorMismatch(ArtifactID)
}
