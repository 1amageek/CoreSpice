import CoreSpiceParsedIR
import OSDIRuntime

/// Immutable programs share their original leases without retaining closed model owners.
internal struct NativeConstitutivePreparationBacking: Sendable {
    let programs: [OSDIPrecisionProgram]
    let control: NativeConstitutivePreparationControl
    let storage: SPICESourceStorageReservation
}
