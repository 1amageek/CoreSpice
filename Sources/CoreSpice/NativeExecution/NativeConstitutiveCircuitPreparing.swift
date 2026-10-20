import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceParsedIR

/// Same-owner controlled preparation lanes; ordinary public preparation remains unchanged.
public protocol NativeConstitutiveCircuitPreparing: NativeCircuitPreparing {
    func prepareNativeConstitutive(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
        resources: any SPICESourceResourceAccounting, cancellation: CancellationToken)
        throws(SPICENativePreparationError) -> PreparedNativeCircuit

    func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
        resources: any SPICESourceResourceAccounting, osdi: SPICEOSDIRuntimeInputs,
        constitutive: NativeConstitutivePreparationInputs, cancellation: CancellationToken)
        async throws(SPICENativePreparationError) -> PreparedNativeCircuit
}
