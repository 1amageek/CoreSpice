import CoreSpiceMOSContracts
import Synchronization

final class BSIM45TestControl: MOSPreparationControlling {
    private let checks = Mutex(0)
    private let cancelAfter: Int
    init(cancelAfter: Int) { self.cancelAfter = cancelAfter }
    func checkCancellation() throws(MOSPreparationFailure) {
        let count = checks.withLock { $0 += 1; return $0 }
        if count > cancelAfter { throw .cancelled }
    }
    func chargeWork(units: UInt64) throws(MOSPreparationFailure) {}
}
