import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Bridges bounded source accounting without introducing another mutable budget owner.
internal struct NativeMOSPreparationControl: MOSPreparationControlling {
    let resources: any SPICESourceResourceAccounting
    func checkCancellation() throws(MOSPreparationFailure) {
        do { try resources.checkCancellation() } catch { throw .cancelled }
    }
    func chargeWork(units: UInt64) throws(MOSPreparationFailure) {
        try checkCancellation()
        do { try resources.charge(.retainedElements, units: units) }
        catch is CancellationError { throw .cancelled }
        catch let error as SPICESimulationResources.ResourceError {
            if case .cancelled = error { throw .cancelled }
            throw .workLimitExceeded
        }
        catch {
            if Task.isCancelled { throw .cancelled }
            throw .workLimitExceeded
        }
    }
}
