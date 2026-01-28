import CoreSpiceCompile
import CoreSpiceIR
import Foundation

/// The result of an AC small-signal frequency-domain analysis.
///
/// Stores one complex solution vector per frequency point, along with
/// convenience accessors for magnitude (in dB) and phase (in degrees).
public struct ACResult: Sendable {

    /// The frequency values at which the AC analysis was evaluated.
    public let frequencies: [Double]

    /// Complex solution vectors, one per frequency point.
    ///
    /// `solutions[f][i]` is the complex value of MNA variable `i`
    /// at frequency `frequencies[f]`.
    public let solutions: [[ComplexPair]]

    /// Mapping from MNA variables to indices in each solution vector.
    public let variableMap: [MNAVariable: Int]

    public init(
        frequencies: [Double],
        solutions: [[ComplexPair]],
        variableMap: [MNAVariable: Int]
    ) {
        self.frequencies = frequencies
        self.solutions = solutions
        self.variableMap = variableMap
    }

    /// Returns the complex voltage at the given node for a specific frequency index.
    ///
    /// Ground always returns zero.
    public func voltage(at node: Node, frequencyIndex: Int) -> ComplexPair {
        if node == .ground { return ComplexPair(real: 0, imag: 0) }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            return ComplexPair(real: 0, imag: 0)
        }
        return solutions[frequencyIndex][idx]
    }

    /// Returns the voltage magnitude in decibels at the given node and frequency.
    public func magnitudeDB(at node: Node, frequencyIndex: Int) -> Double {
        let v = voltage(at: node, frequencyIndex: frequencyIndex)
        return 20.0 * log10(max(v.magnitude, 1e-300))
    }

    /// Returns the voltage phase in degrees at the given node and frequency.
    public func phase(at node: Node, frequencyIndex: Int) -> Double {
        let v = voltage(at: node, frequencyIndex: frequencyIndex)
        return atan2(v.imag, v.real) * 180.0 / .pi
    }
}
