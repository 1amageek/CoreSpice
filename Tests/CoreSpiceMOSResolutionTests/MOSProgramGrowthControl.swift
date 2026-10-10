import CoreSpiceMOSContracts
import Synchronization

/// Measures actual retained-capacity work without changing the local storage ceiling.
final class MOSProgramGrowthControl: MOSResolutionControlling {
    private let total = Mutex<UInt64>(0)
    private let maximumRetainedByteWork: UInt64
    private let maximumSingleRetainedByteCharge: UInt64

    init(maximumRetainedByteWork: UInt64 = .max, maximumSingleRetainedByteCharge: UInt64 = .max) {
        self.maximumRetainedByteWork = maximumRetainedByteWork
        self.maximumSingleRetainedByteCharge = maximumSingleRetainedByteCharge
    }
    var retainedByteWork: UInt64 { total.withLock { $0 } }
    func checkCancellation() throws(MOSResolutionFailure) {}
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        guard kind == .retainedBytes else { return }
        guard units <= maximumSingleRetainedByteCharge else { throw .cancelled }
        try total.withLock { (value: inout UInt64) throws(MOSResolutionFailure) in
            guard units <= maximumRetainedByteWork - value else { throw .limitExceeded(.evaluationSteps) }
            value += units
        }
    }
}
