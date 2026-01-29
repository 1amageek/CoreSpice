import Foundation

/// Describes how a device parameter varies in a Monte Carlo analysis.
public struct ParameterVariation: Sendable {
    /// The device instance name (e.g., "R1").
    public let deviceName: String
    /// The parameter name (e.g., "r").
    public let parameterName: String
    /// The nominal parameter value.
    public let nominalValue: Double
    /// The statistical distribution for the variation.
    public let distribution: Distribution

    /// Statistical distributions for parameter variation.
    public enum Distribution: Sendable {
        /// Gaussian (normal) distribution with the given standard deviation.
        case gaussian(sigma: Double)
        /// Uniform distribution with the given half-range.
        /// Value varies in [nominal - range, nominal + range].
        case uniform(range: Double)
    }

    public init(
        deviceName: String,
        parameterName: String,
        nominalValue: Double,
        distribution: Distribution
    ) {
        self.deviceName = deviceName
        self.parameterName = parameterName
        self.nominalValue = nominalValue
        self.distribution = distribution
    }

    /// Samples a random value from this variation's distribution.
    func sample(rng: inout some RandomNumberGenerator) -> Double {
        switch distribution {
        case .gaussian(let sigma):
            return nominalValue + gaussianSample(rng: &rng) * sigma
        case .uniform(let range):
            let u = Double.random(in: -1.0...1.0, using: &rng)
            return nominalValue + u * range
        }
    }

    /// Box-Muller transform for Gaussian sampling.
    private func gaussianSample(rng: inout some RandomNumberGenerator) -> Double {
        let u1 = Double.random(in: Double.leastNormalMagnitude...1.0, using: &rng)
        let u2 = Double.random(in: 0.0...1.0, using: &rng)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

/// A simple seeded random number generator for reproducible Monte Carlo runs.
///
/// Uses the SplitMix64 algorithm for fast, deterministic pseudorandom generation.
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
