import CoreSpiceIO

public protocol SPICENativePreparing: Sendable {
    func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits)
        throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation
    func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits,
                 osdi: SPICEOSDIRuntimeInputs) async throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation
}

extension SPICENativePreparing {
    public func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits,
                        osdi: SPICEOSDIRuntimeInputs) async throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation {
        // FIXME(INCOMPLETE_IMPLEMENTATION): The legacy conformer's default async witness does not implement OSDI setup.
        // Production OSDI callers must use an overriding implementation; successful setup, original physical DC
        // acceptance, exact receipts and explicit cleanup must be behaviorally verified before this lane can succeed.
        guard !input.circuit.instances.contains(where: { $0.osdi != nil || $0.typeName == "osdi" }) else {
            throw .unsupportedCapability("This native preparer has no OSDI runtime implementation")
        }
        return try prepare(input, limits: limits)
    }
}
