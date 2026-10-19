import CoreSpiceDiodeContracts

public protocol DiodePreparationControlling: Sendable {
    func checkCancellation() throws(DiodePreparationFailure)
    func chargeWork(_ units: UInt64) throws(DiodePreparationFailure)
}
