/// Cancellation and counted work are requirements, including under Embedded Swift.
public protocol MOSResolutionControlling: Sendable {
    func checkCancellation() throws(MOSResolutionFailure)
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure)
}
