import CoreSpiceIR

/// Qualified actual producers enumerate complete conservative support without an owned array.
package protocol ContinuousEquationStructureProviding: BoundDevice {
    func visitContinuousEquationStructure(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void
    ) throws
}

/// This local check does not replace the caller's complete compiled-axis join.
func continuousEquationNodeIndex(_ node: Node, index: Int?, device: String) throws -> Int? {
    if node == .ground {
        guard index == nil else { throw ContinuousEquationStructureFailure.invalidBinding(device: device) }
        return nil
    }
    guard let index, index >= 0 else { throw ContinuousEquationStructureFailure.invalidBinding(device: device) }
    return index
}

func visitContinuousEquationNode(_ node: Node, index: Int?, device: String,
    access: ContinuousEquationAccess, checkpoint: () throws -> Void,
    visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void) throws {
    try checkpoint()
    if let index = try continuousEquationNodeIndex(node, index: index, device: device) {
        try visit(access, .nodeVoltage(node), index)
    }
}
