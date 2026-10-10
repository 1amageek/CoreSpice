import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceParsedIR

/// Composes exact resolved device inputs into one exclusive native circuit.
public protocol NativeCircuitPreparing: Sendable {
    func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                 limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                 resources: any SPICESourceResourceAccounting)
        throws(SPICENativePreparationError) -> PreparedNativeCircuit
}
