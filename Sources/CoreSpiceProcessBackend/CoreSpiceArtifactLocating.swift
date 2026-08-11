import CircuiteFoundation
import CircuiteFoundationFoundation

public protocol CoreSpiceArtifactLocating: Sendable {
    func locator(
        for reference: ArtifactReference
    ) throws(CoreSpiceArtifactLocatorError) -> ArtifactLocator
}
