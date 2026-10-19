import Foundation
import CircuiteFoundation
import CircuiteFoundationFileSystem

/// Acquires a fresh local root for each explicitly bounded artifact read.
public struct SPICEOSDILocalArtifactSource: ArtifactAccessing {
    private let rootID: ArtifactRootID
    private let directoryURL: URL
    private let digester: any ContentDigesting

    public init(rootID: ArtifactRootID, directoryURL: URL, digester: any ContentDigesting) throws(ArtifactAccessError) {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            throw .invalidRoot(reason: "The OSDI artifact root must be an absolute file URL")
        }
        self.rootID = rootID; self.directoryURL = directoryURL; self.digester = digester
    }

    public func open(_ intent: ArtifactAccessIntent) async throws(ArtifactAccessError) -> any ArtifactReadSession {
        guard !Task.isCancelled else { throw .cancelled }
        guard intent.operation == .read else {
            throw .unsupportedCapability(reason: "The OSDI artifact source requires an explicit read intent")
        }
        guard case .local(_, let selectedRoot, _) = intent.availability else { throw .availabilityNotLocal }
        guard selectedRoot == rootID else { throw .rootMismatch(expected: rootID, actual: selectedRoot) }
        let root: ArtifactRootCapability
        do { root = try ArtifactRootCapability(rootID: rootID, directoryURL: directoryURL, digester: digester) }
        catch { throw .invalidRoot(reason: String(describing: error)) }
        let session: any ArtifactReadSession
        do { session = try await root.open(intent) }
        catch {
            let primary = error
            do { try await root.close().wait() }
            catch { throw .cleanupFailed(primary: String(describing: primary), closeReason: String(describing: error)) }
            throw primary
        }
        let owned = SPICEOSDIOwnedArtifactReadSession(session: session, root: root)
        if Task.isCancelled { throw await owned.closingAfter(.cancelled) }
        return owned
    }
}

/// Owns both resources; underlying session retirement must precede root draining.
private actor SPICEOSDIOwnedArtifactReadSession: ArtifactReadSession {
    nonisolated let identity: ArtifactAccessSessionIdentity
    nonisolated let expectedReference: ArtifactReference
    private let session: any ArtifactReadSession
    private let root: ArtifactRootCapability
    private var termination: SPICEOSDIArtifactTermination?

    init(session: any ArtifactReadSession, root: ArtifactRootCapability) {
        identity = session.identity; expectedReference = session.expectedReference
        self.session = session; self.root = root
    }

    func readPage(_ request: ArtifactReadPageRequest) async throws(ArtifactAccessError) -> ArtifactReadPage {
        guard termination == nil else { throw .sessionClosed }
        let page: ArtifactReadPage
        do throws(ArtifactAccessError) {
            guard !Task.isCancelled else { throw ArtifactAccessError.cancelled }
            page = try await session.readPage(request)
            guard !Task.isCancelled else { throw ArtifactAccessError.cancelled }
        } catch { throw await closingAfter(error) }
        if page.completion == .complete {
            do { _ = try await close().wait() }
            catch { throw .fileCloseFailed(reason: String(describing: error)) }
        }
        return page
    }

    func close() async -> any ArtifactAccessTermination {
        if let termination { return termination }
        // This unstructured cleanup task is shared by every close/wait caller.
        // It never inherits caller cancellation and never waits for root drain
        // until the actual read session has retired its root admission.
        let actualSession = session, actualRoot = root
        let task = Task { () -> Result<ArtifactAccessTerminationReceipt, ArtifactAccessTerminationError> in
            let sessionTermination = await actualSession.close()
            var receipt: ArtifactAccessTerminationReceipt?
            var sessionFailure: String?
            do { receipt = try await sessionTermination.wait() }
            catch { sessionFailure = String(describing: error) }
            var rootFailure: String?
            do { try await actualRoot.close().wait() }
            catch { rootFailure = String(describing: error) }
            if let sessionFailure {
                return .failure(.cleanupFailed(reason: "Read session: \(sessionFailure)" + (rootFailure.map { "; artifact root: \($0)" } ?? "")))
            }
            if let rootFailure { return .failure(.cleanupFailed(reason: "Artifact root: \(rootFailure)")) }
            guard let receipt else { return .failure(.cleanupFailed(reason: "Read session returned no termination receipt")) }
            return .success(receipt)
        }
        let stable = SPICEOSDIArtifactTermination(sessionIdentity: identity, task: task)
        termination = stable
        return stable
    }

    func closingAfter(_ primary: ArtifactAccessError) async -> ArtifactAccessError {
        do { _ = try await close().wait() }
        catch { return .cleanupFailed(primary: String(describing: primary), closeReason: String(describing: error)) }
        return primary
    }
}

private actor SPICEOSDIArtifactTermination: ArtifactAccessTermination {
    nonisolated let sessionIdentity: ArtifactAccessSessionIdentity
    private let task: Task<Result<ArtifactAccessTerminationReceipt, ArtifactAccessTerminationError>, Never>

    init(sessionIdentity: ArtifactAccessSessionIdentity,
         task: Task<Result<ArtifactAccessTerminationReceipt, ArtifactAccessTerminationError>, Never>) {
        self.sessionIdentity = sessionIdentity; self.task = task
    }

    func wait() async throws(ArtifactAccessTerminationError) -> ArtifactAccessTerminationReceipt {
        switch await task.value {
        case .success(let receipt): return receipt
        case .failure(let error): throw error
        }
    }
}
