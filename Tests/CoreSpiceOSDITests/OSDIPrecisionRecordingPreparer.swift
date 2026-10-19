import CircuiteFoundation
import OSDIContracts
import OSDIRuntime
import Synchronization

/// Records whether cold capacity admission reached the precision boundary.
final class RecordingPreparer: OSDIPrecisionSessionPreparing {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func snapshot(library: borrowing OSDILibrary, descriptorIndex: Int, model: borrowing OSDIPreparedModel,
        preparation: OSDIPreparationOptions, semanticProfile: ContentDigest,
        options: OSDIPrecisionOptions) throws(OSDIError) -> OSDIPrecisionProgram {
        count.withLock { $0 += 1 }
        throw .closed
    }
    func prepare(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent, source: any ArtifactAccessing,
        numericProfile: ContentDigest, options: OSDIPrecisionOptions) async throws(OSDIError) -> OSDIPrecisionSession {
        throw .closed
    }
}
