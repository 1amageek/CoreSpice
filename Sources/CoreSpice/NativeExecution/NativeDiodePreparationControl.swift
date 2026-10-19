import CoreSpiceDiodeContracts
import CoreSpiceDevices
import CoreSpiceParsedIR

struct NativeDiodePreparationControl: DiodePreparationControlling {
    let resources: any SPICESourceResourceAccounting
    func checkCancellation() throws(DiodePreparationFailure) {
        do { try resources.checkCancellation() } catch { throw .cancelled }
    }
    func chargeWork(_ units: UInt64) throws(DiodePreparationFailure) {
        do { try resources.charge(.retainedElements, units: units) } catch { throw .workLimitExceeded }
    }
}
