/// Source stepping strategy for DC operating point convergence.
///
/// Ramps all independent sources from zero to their full value in
/// equal increments. This helps circuits with strong nonlinearities
/// (such as BJTs or diodes) converge by starting from a simpler
/// operating condition.
public struct SourceStepping: Sendable {

    /// Number of equal steps from 0 to 1.
    public let steps: Int

    public init(steps: Int = 10) {
        self.steps = steps
    }

    /// Generates the source scaling factors: `1/steps, 2/steps, ..., 1.0`.
    ///
    /// The first factor is always greater than zero and the last is always 1.0.
    public func sourceFactors() -> [Double] {
        (1...steps).map { Double($0) / Double(steps) }
    }
}
