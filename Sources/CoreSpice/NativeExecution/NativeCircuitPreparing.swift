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
    func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                 limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                 resources: any SPICESourceResourceAccounting, osdi: SPICEOSDIRuntimeInputs)
        async throws(SPICENativePreparationError) -> PreparedNativeCircuit
}

extension NativeCircuitPreparing {
    public func prepare(ir: CircuitIR, registry: DeviceRegistry, operatingConditions: OperatingConditions,
                        limits: SPICENativeExecutionLimits, numericalLimits: TransientExecutionLimits,
                        resources: any SPICESourceResourceAccounting, osdi: SPICEOSDIRuntimeInputs)
        async throws(SPICENativePreparationError) -> PreparedNativeCircuit {
        // FIXME(INCOMPLETE_IMPLEMENTATION): The legacy conformer's default async witness does not implement OSDI setup.
        // Production OSDI callers must use an overriding implementation; successful setup, original physical DC
        // acceptance, exact receipts and explicit cleanup must be behaviorally verified before this lane can succeed.
        guard !ir.instances.contains(where: { $0.osdi != nil || $0.typeName == "osdi" }) else {
            throw .unsupportedCapability("This native preparer has no OSDI runtime implementation")
        }
        return try prepare(ir: ir, registry: registry, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, resources: resources)
    }
}
