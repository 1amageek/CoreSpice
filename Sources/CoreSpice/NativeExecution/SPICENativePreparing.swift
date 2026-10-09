import CoreSpiceIO

public protocol SPICENativePreparing: Sendable {
    func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits)
        throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation
}
