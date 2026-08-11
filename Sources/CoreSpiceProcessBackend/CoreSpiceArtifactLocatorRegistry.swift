import CircuiteFoundation
import CircuiteFoundationFoundation

public struct CoreSpiceArtifactLocatorRegistry: CoreSpiceArtifactLocating {
    private let locatorsByArtifactID: [ArtifactID: ArtifactLocator]

    public init(locatorsByArtifactID: [ArtifactID: ArtifactLocator] = [:]) {
        self.locatorsByArtifactID = locatorsByArtifactID
    }

    public func locator(
        for reference: ArtifactReference
    ) throws(CoreSpiceArtifactLocatorError) -> ArtifactLocator {
        guard let locator = locatorsByArtifactID[reference.id] else {
            throw .missingLocation(reference.id)
        }
        guard locator.descriptor == reference.descriptor else {
            throw .descriptorMismatch(reference.id)
        }
        return locator
    }
}
