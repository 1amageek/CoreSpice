import CoreSpiceEvent
import CoreSpiceIO

/// Uses the actual SPICE finish path without expanding the ordinary public operation.
public protocol NativeConstitutiveSPICEPreparing: SPICENativePreparing {
    func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits,
        osdi: SPICEOSDIRuntimeInputs, constitutive: NativeConstitutivePreparationInputs,
        cancellation: CancellationToken) async throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation
}
