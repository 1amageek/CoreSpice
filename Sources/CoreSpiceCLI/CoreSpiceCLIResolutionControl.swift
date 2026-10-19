import CoreSpiceEvent
import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Synchronization

/// The source evaluation participates in the same counted invocation resources as preparation.
final class CoreSpiceCLIResolutionControl: MOSResolutionControlling {
    private struct ResourceFailure: Sendable {
        let cause: any Error
        let translated: MOSResolutionFailure
    }
    let resources: SPICESimulationResources
    let cancellation: CancellationToken?
    private let firstResourceFailure = Mutex<ResourceFailure?>(nil)
    init(resources: SPICESimulationResources, cancellation: CancellationToken?) {
        self.resources = resources; self.cancellation = cancellation
    }
    func checkCancellation() throws(MOSResolutionFailure) {
        guard !Task.isCancelled, cancellation?.isCancelled != true else { throw .cancelled }
        do { try resources.checkCancellation() }
        catch { record(error, translated: .cancelled); throw .cancelled }
    }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        try checkCancellation()
        do { try resources.charge(.retainedElements, units: units) }
        catch { record(error, translated: .limitExceeded(kind)); throw .limitExceeded(kind) }
    }
    private func record(_ error: any Error, translated: MOSResolutionFailure) {
        firstResourceFailure.withLock { if $0 == nil { $0 = .init(cause: error, translated: translated) } }
    }
    func preservingResourceCause(_ error: any Error) -> any Error {
        guard let failure = firstResourceFailure.withLock({ $0 }) else { return error }
        if let resolution = error as? MOSResolutionFailure, resolution == failure.translated {
            return SPICESimulationPreparationError.resolution(resolution, resourceCause: failure.cause)
        }
        if let condition = error as? MOSConditionEvaluationFailure, condition.cause == failure.translated {
            return SPICESimulationPreparationError.condition(condition, resourceCause: failure.cause)
        }
        if let preparation = error as? SPICESimulationPreparationError,
           case .diodeResolution(let diode, nil, let reservation) = preparation,
           case .evaluation(let resolution) = diode.cause, resolution == failure.translated {
            return SPICESimulationPreparationError.diodeResolution(diode,
                resourceCause: failure.cause, reservation: reservation)
        }
        return error
    }
}
