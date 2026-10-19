import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Each successful call must return an independently leased native image.
public protocol OSDILibraryProviding: Sendable {
    func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary
}
