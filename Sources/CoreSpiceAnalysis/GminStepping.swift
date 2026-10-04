/// Gmin stepping strategy for finding DC operating points.
///
/// Starts with a large minimum conductance (`initialGmin`) that makes
/// the matrix well-conditioned, then progressively reduces it to the
/// target value (`finalGmin`). At each step the previous solution
/// serves as the initial guess for the next Newton-Raphson solve.
public struct GminStepping: Sendable {

    /// Starting (large) conductance value.
    public let initialGmin: Double

    /// Target (small) conductance value.
    public let finalGmin: Double

    /// Factor by which Gmin is divided at each step.
    public let reductionFactor: Double

    /// Maximum number of stepping stages.
    public let maxSteps: Int

    public init(
        initialGmin: Double = 1e-3,
        finalGmin: Double = 1e-12,
        reductionFactor: Double = 10.0,
        maxSteps: Int = 10
    ) {
        self.initialGmin = initialGmin
        self.finalGmin = finalGmin
        self.reductionFactor = reductionFactor
        self.maxSteps = maxSteps
    }

    /// Lazily generates recovery stages so run admission bounds stage creation.
    func lazyValues() -> some Sequence<Double> {
        sequence(state: (value: initialGmin, count: 0, finished: false)) { state in
            guard !state.finished else { return nil }
            guard state.value > finalGmin, state.count < maxSteps else {
                state.finished = true
                return finalGmin
            }
            let value = state.value
            state.value /= reductionFactor
            state.count += 1
            return value
        }
    }

    /// Generates the sequence of Gmin values from `initialGmin` down to `finalGmin`.
    ///
    /// The sequence divides by `reductionFactor` at each step and always
    /// includes `finalGmin` as the last element.
    public func gminValues() -> [Double] {
        var values: [Double] = []
        var g = initialGmin
        while g > finalGmin && values.count < maxSteps {
            values.append(g)
            g /= reductionFactor
        }
        values.append(finalGmin)
        return values
    }
}
