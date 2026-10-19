import CoreSpiceCompile

/// Pointwise algebraic observations, never an internal/pole/broadband stability certificate.
public struct TwoPortStability: Sendable, Equatable {
    public enum Metric: Sendable, Equatable {
        case defined(Double)
        case undefined(Reason)
    }
    public enum Reason: String, Sendable, Equatable {
        case zeroDenominator
        case nonFiniteArithmetic
    }
    public let delta: ComplexPair
    public let rollettK: Metric
    public let mu: Metric
    public let reverseMu: Metric
    /// Nil means K is undefined; this is only K > 1 and |delta| < 1 at this sample.
    public let satisfiesRollettInequalities: Bool?

    /// Decodes saved scalar observations without granting source or mathematical authority.
    /// Pass this value through `NetworkParameterPoint.validatingSaved` before accepting it.
    public init(savedDelta: ComplexPair, rollettK: Metric, mu: Metric, reverseMu: Metric,
                satisfiesRollettInequalities: Bool?) throws {
        guard savedDelta.real.isFinite, savedDelta.imag.isFinite else {
            throw NetworkParameterError.nonFinite("saved two-port determinant")
        }
        for metric in [rollettK, mu, reverseMu] {
            if case .defined(let value) = metric, !value.isFinite {
                throw NetworkParameterError.nonFinite("saved two-port metric")
            }
        }
        self.delta = savedDelta; self.rollettK = rollettK; self.mu = mu; self.reverseMu = reverseMu
        self.satisfiesRollettInequalities = satisfiesRollettInequalities
    }

    public init(scattering: NetworkParameterMatrix) throws {
        guard scattering.portCount == 2 else {
            throw NetworkParameterError.invalidConfiguration("Two-port metrics require two ports")
        }
        let s11 = scattering.values[0], s12 = scattering.values[1]
        let s21 = scattering.values[2], s22 = scattering.values[3]
        let product = s12 * s21
        let delta = s11 * s22 - product
        guard delta.real.isFinite, delta.imag.isFinite else {
            throw NetworkParameterError.nonFinite("two-port determinant")
        }
        self.delta = delta
        let a = s11.magnitude, b = s22.magnitude, d = delta.magnitude
        rollettK = Self.ratio(1 - a * a - b * b + d * d, 2 * product.magnitude)
        mu = Self.ratio(1 - a * a, (s22 - delta * s11.conjugate).magnitude + product.magnitude)
        reverseMu = Self.ratio(1 - b * b, (s11 - delta * s22.conjugate).magnitude + product.magnitude)
        if case .defined(let k) = rollettK {
            satisfiesRollettInequalities = k > 1 && d < 1
        } else {
            satisfiesRollettInequalities = nil
        }
    }

    private static func ratio(_ numerator: Double, _ denominator: Double) -> Metric {
        guard numerator.isFinite, denominator.isFinite else { return .undefined(.nonFiniteArithmetic) }
        guard denominator != 0 else { return .undefined(.zeroDenominator) }
        let value = numerator / denominator
        return value.isFinite ? .defined(value) : .undefined(.nonFiniteArithmetic)
    }
}
