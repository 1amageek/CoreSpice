import CoreSpiceCompile

/// Immutable row-major matrix: response port is the row, excitation port is the column.
public struct NetworkParameterMatrix: Sendable, Equatable {
    public let portCount: Int
    public let values: [ComplexPair]

    public init(portCount: Int, values: [ComplexPair]) throws {
        let (count, overflow) = portCount.multipliedReportingOverflow(by: portCount)
        guard portCount > 0, !overflow, count == values.count else {
            throw NetworkParameterError.invalidMatrix
        }
        guard values.allSatisfy({ $0.real.isFinite && $0.imag.isFinite }) else {
            throw NetworkParameterError.nonFinite("network matrix")
        }
        self.portCount = portCount
        self.values = values
    }

    public func value(row: Int, column: Int) throws -> ComplexPair {
        guard row >= 0, row < portCount, column >= 0, column < portCount else {
            throw NetworkParameterError.matrixIndex(row: row, column: column)
        }
        return values[row * portCount + column]
    }
}
