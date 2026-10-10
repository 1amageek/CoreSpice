import CoreSpiceEvent
import CoreSpiceIO
import CoreSpiceMOSContracts

/// The source evaluation participates in the same counted invocation resources as preparation.
struct CoreSpiceCLIResolutionControl: MOSResolutionControlling {
    let resources: SPICESimulationResources
    let cancellation: CancellationToken?
    func checkCancellation() throws(MOSResolutionFailure) {
        guard !Task.isCancelled, cancellation?.isCancelled != true else { throw .cancelled }
        do { try resources.checkCancellation() } catch { throw .cancelled }
    }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        try checkCancellation()
        do { try resources.charge(.retainedElements, units: units) }
        catch { throw .limitExceeded(kind) }
    }
}
