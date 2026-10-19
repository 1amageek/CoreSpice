import CoreSpiceCompile
import OSDIRuntime

/// Delegates SDK-owned construction accounting to the existing request owner.
struct OSDIConstitutiveSnapshotControl: OSDIPrecisionSnapshotControlling {
    let control: any LinearSolverExecutionControlling

    func checkpoint(workUnits: UInt64) throws {
        try control.checkpoint(workUnits: OSDIConstitutiveCapacity.integer(workUnits))
    }

    func reserveStorage(byteCount: UInt64) throws -> any Sendable {
        try control.reserveStorage(byteCount: OSDIConstitutiveCapacity.integer(byteCount))
    }
}
