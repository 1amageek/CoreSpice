/// Independent noise sources exciting arbitrary canonical residual equations.
public protocol ResidualNoisyDevice: BoundDevice {
    /// Prepared immutable source order, retained once by an analysis.
    var residualNoiseSources: [ResidualNoiseSource] { get }
    /// Invokes body exactly once with fresh densities at the supplied OP and frequency in Hz.
    /// The density span is synchronous and must not escape; evaluation and body run outside locks.
    func withNoiseDensities(state: SolutionState, frequency: Double,
        _ body: (borrowing Span<Double>) throws -> Void) throws
}
