import CoreSpiceIR

/// One exact represented-coefficient term, separate from floating-point evaluation rounding.
package struct ContinuousEquationLinearTerm: Sendable, Equatable {
    package let plane: ContinuousEquationPlane
    package let equation: MNAVariable
    package let row: Int
    package let coordinate: MNAVariable
    package let column: Int
    package let coefficientBits: UInt64

    init(plane: ContinuousEquationPlane, equation: MNAVariable, row: Int,
        coordinate: MNAVariable, column: Int, coefficient: Double, device: String) throws {
        guard row >= 0, column >= 0 else {
            throw ContinuousEquationStructureFailure.invalidBinding(device: device)
        }
        guard coefficient.isFinite else {
            throw ContinuousEquationStructureFailure.nonFiniteCoefficient(device: device)
        }
        self.plane = plane; self.equation = equation; self.row = row
        self.coordinate = coordinate; self.column = column
        coefficientBits = coefficient.bitPattern
    }

    /// Checks local identities only; the consumer must supply the same complete compiled axis.
    package func validateJoin(variableMap: [MNAVariable: Int], device: String) throws {
        guard variableMap[equation] == row, variableMap[coordinate] == column else {
            throw ContinuousEquationStructureFailure.invalidBinding(device: device)
        }
    }
}
