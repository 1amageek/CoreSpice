import Foundation
import CircuiteFoundation
import CircuiteFoundationFileSystem
import CoreSpiceOSDI
import OSDIContracts
import OSDIRuntime

/// Opens a bounded local capability per acquisition, then returns an independent staged image.
public struct SPICEOSDILocalLibraryProvider: OSDILibraryProviding {
    private let rootID: ArtifactRootID
    private let directoryURL: URL
    private let intents: [ArtifactReference: ArtifactAccessIntent]
    private let stagingParentDirectory: URL
    private let digester: any ContentDigesting
    public init(rootID: ArtifactRootID, directoryURL: URL, intents: [ArtifactAccessIntent],
                stagingParentDirectory: URL, digester: any ContentDigesting) throws(OSDIError) {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/"),
              stagingParentDirectory.isFileURL, stagingParentDirectory.path.hasPrefix("/"), !intents.isEmpty else { throw .invalidRange }
        var routes: [ArtifactReference: ArtifactAccessIntent] = [:]
        for intent in intents {
            guard intent.operation == .read, case .local(_, let selectedRoot, _) = intent.availability,
                  selectedRoot == rootID, routes.updateValue(intent, forKey: intent.expectedReference) == nil else { throw .identityMismatch }
        }
        self.rootID = rootID; self.directoryURL = directoryURL; self.intents = routes
        self.stagingParentDirectory = stagingParentDirectory; self.digester = digester
    }
    public func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
        guard let intent = intents[reference] else { throw .identityMismatch }
        let root: ArtifactRootCapability
        do { root = try ArtifactRootCapability(rootID: rootID, directoryURL: directoryURL, digester: digester) }
        catch { throw .host(operation: "open OSDI artifact root", underlying: error) }
        let library: OSDILibrary
        do { library = try await OSDINativeLibraryLoader(stagingParentDirectory: stagingParentDirectory).load(intent, source: root, limits: limits) }
        catch {
            let primary = error
            do { try await root.close().wait() }
            catch { throw .cleanup(primary: primary, secondary: .host(operation: "close OSDI artifact root", underlying: error)) }
            throw primary
        }
        do { try await root.close().wait() }
        catch {
            let primary = OSDIError.host(operation: "close OSDI artifact root", underlying: error)
            do { try library.close() }
            catch { throw .cleanup(primary: primary, secondary: error) }
            throw primary
        }
        return library
    }
}
