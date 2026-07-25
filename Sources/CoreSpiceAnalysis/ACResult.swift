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
    ) throws {
        guard frequencies.count == solutions.count else {
            throw ACResultError.frequencySolutionCountMismatch(
                frequencies: frequencies.count,
                solutions: solutions.count
            )
        }
        for (index, frequency) in frequencies.enumerated() where !frequency.isFinite {
            throw ACResultError.nonFiniteFrequency(index: index, value: frequency)
        }
        let solutionSize = solutions.first?.count ?? 0
        for (index, solution) in solutions.enumerated() where solution.count != solutionSize {
            throw ACResultError.inconsistentSolutionSize(
                index: index,
                expected: solutionSize,
                actual: solution.count
            )
        }
        for (variable, index) in variableMap
            where index < 0 || index >= solutionSize {
            throw ACResultError.variableIndexOutOfBounds(
                variable: variable,
                index: index,
                count: solutionSize
            )
        }
        self.frequencies = frequencies
        self.solutions = solutions
        self.variableMap = variableMap
    }

    /// Returns the complex voltage at the given node for a specific frequency index.
    ///
    /// Ground always returns zero.
    public func voltage(at node: Node, frequencyIndex: Int) throws -> ComplexPair {
        guard frequencies.indices.contains(frequencyIndex) else {
            throw ACResultError.frequencyIndexOutOfBounds(
                index: frequencyIndex,
                count: frequencies.count
            )
        }
        if node == .ground { return ComplexPair(real: 0, imag: 0) }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            throw ACResultError.missingNodeVoltage(nodeID: node.id)
        }
        return solutions[frequencyIndex][idx]
    }

    /// Returns the voltage magnitude in decibels at the given node and frequency.
    public func magnitudeDB(at node: Node, frequencyIndex: Int) throws -> Double {
        let v = try voltage(at: node, frequencyIndex: frequencyIndex)
        return 20.0 * log10(max(v.magnitude, 1e-300))
    }

    /// Returns the voltage phase in degrees at the given node and frequency.
    public func phase(at node: Node, frequencyIndex: Int) throws -> Double {
        let v = try voltage(at: node, frequencyIndex: frequencyIndex)
        return atan2(v.imag, v.real) * 180.0 / .pi
    }
}
