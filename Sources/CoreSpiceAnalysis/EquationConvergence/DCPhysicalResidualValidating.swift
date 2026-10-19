import CoreSpiceDevices

/// Validates original physical DC equations independently before accepted-state publication.
/// Implementations throw their original diagnostic when any physical equation fails.
public protocol DCPhysicalResidualValidating: Sendable {
    func validate(state: SolutionState) throws
}
