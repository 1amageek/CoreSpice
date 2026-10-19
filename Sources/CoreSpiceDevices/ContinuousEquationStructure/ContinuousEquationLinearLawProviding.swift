import CoreSpiceIR

/// Complete native R/C/V coordinate laws; source value laws are retained separately.
package protocol ContinuousEquationLinearLawProviding: ContinuousEquationStructureProviding {
    /// The caller owns work/cancellation checkpoints and admission before retaining terms.
    /// A callback failure may expose a prefix, which cannot be used as a complete law.
    func visitContinuousEquationLinearLaw(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationLinearTerm) throws -> Void) throws
}

func visitContinuousEquationLinearTerm(plane: ContinuousEquationPlane,
    equation: MNAVariable, row: Int?, coordinate: MNAVariable, column: Int?,
    coefficient: Double, device: String, checkpoint: () throws -> Void,
    visit: (ContinuousEquationLinearTerm) throws -> Void) throws {
    try checkpoint()
    guard let row, let column else { return }
    try visit(.init(plane: plane, equation: equation, row: row, coordinate: coordinate,
        column: column, coefficient: coefficient, device: device))
}

/// The four candidates include omitted ground terms and preserve duplicate incidences.
func visitContinuousEquationTwoTerminalLaw(positive: Node, negative: Node,
    positiveIndex: Int?, negativeIndex: Int?, plane: ContinuousEquationPlane,
    coefficient: Double, device: String, checkpoint: () throws -> Void,
    visit: (ContinuousEquationLinearTerm) throws -> Void) throws {
    try checkpoint()
    guard coefficient.isFinite else {
        throw ContinuousEquationStructureFailure.nonFiniteCoefficient(device: device)
    }
    try checkpoint()
    let p = try continuousEquationNodeIndex(positive, index: positiveIndex, device: device)
    try checkpoint()
    let n = try continuousEquationNodeIndex(negative, index: negativeIndex, device: device)
    try visitContinuousEquationLinearTerm(plane: plane,
        equation: .nodeVoltage(positive), row: p, coordinate: .nodeVoltage(positive), column: p,
        coefficient: coefficient, device: device, checkpoint: checkpoint, visit: visit)
    try visitContinuousEquationLinearTerm(plane: plane,
        equation: .nodeVoltage(positive), row: p, coordinate: .nodeVoltage(negative), column: n,
        coefficient: -coefficient, device: device, checkpoint: checkpoint, visit: visit)
    try visitContinuousEquationLinearTerm(plane: plane,
        equation: .nodeVoltage(negative), row: n, coordinate: .nodeVoltage(positive), column: p,
        coefficient: -coefficient, device: device, checkpoint: checkpoint, visit: visit)
    try visitContinuousEquationLinearTerm(plane: plane,
        equation: .nodeVoltage(negative), row: n, coordinate: .nodeVoltage(negative), column: n,
        coefficient: coefficient, device: device, checkpoint: checkpoint, visit: visit)
}
