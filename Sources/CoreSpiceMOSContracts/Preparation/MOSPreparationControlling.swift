/// Synchronous cancellation/work requirements remain callable through Embedded existentials.
public protocol MOSPreparationControlling: Sendable {
    func checkCancellation() throws(MOSPreparationFailure)
    func chargeWork(units: UInt64) throws(MOSPreparationFailure)
}
