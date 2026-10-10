import CoreSpiceMOSContracts
import Synchronization

/// Observes the existing evaluator/selector's actual work dimensions.
final class ResolutionMeter: MOSResolutionControlling {
    private let resources: MeasuredResources
    private let counts = Mutex<[String: UInt64]>([:])
    init(resources: MeasuredResources) { self.resources = resources }
    var snapshot: [String: UInt64] { counts.withLock { $0 } }
    func checkCancellation() throws(MOSResolutionFailure) {
        do { try resources.checkCancellation() } catch { throw .cancelled }
    }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        try checkCancellation()
        do { try resources.charge(.retainedElements, units: units) } catch { throw .limitExceeded(kind) }
        counts.withLock { $0[kind.rawValue, default: 0] += units }
    }
}
