import CoreSpiceIR

/// Actual stored DC/transient value laws and coordinate identity; no derivative or history authority.
package struct IndependentVoltageSourceFact: Sendable {
    package let instance: Instance
    package let positiveNode: Node
    package let negativeNode: Node
    package let positiveRow: Int?
    package let negativeRow: Int?
    package let branch: Branch
    package let branchRow: Int
    package let dcVoltage: Double
    package let waveform: Waveform

    init(instance: Instance, positiveNode: Node, negativeNode: Node, positiveRow: Int?,
        negativeRow: Int?, branch: Branch, branchRow: Int?, dcVoltage: Double, waveform: Waveform) throws {
        self.positiveRow = try continuousEquationNodeIndex(positiveNode, index: positiveRow, device: instance.name)
        self.negativeRow = try continuousEquationNodeIndex(negativeNode, index: negativeRow, device: instance.name)
        guard let branchRow, branchRow >= 0, branchRow != positiveRow, branchRow != negativeRow else {
            throw ContinuousEquationStructureFailure.invalidBinding(device: instance.name)
        }
        guard dcVoltage.isFinite else {
            throw ContinuousEquationStructureFailure.invalidSourceLaw(device: instance.name)
        }
        self.instance = instance; self.positiveNode = positiveNode; self.negativeNode = negativeNode
        self.branch = branch; self.branchRow = branchRow; self.dcVoltage = dcVoltage; self.waveform = waveform
    }

    /// Verifies source-local identities; the consumer must also validate the complete axis.
    package func validateJoin(variableMap: [MNAVariable: Int]) throws {
        guard variableMap[.branchCurrent(branch)] == branchRow,
              (positiveNode == .ground ? nil : variableMap[.nodeVoltage(positiveNode)]) == positiveRow,
              (negativeNode == .ground ? nil : variableMap[.nodeVoltage(negativeNode)]) == negativeRow else {
            throw ContinuousEquationStructureFailure.invalidBinding(device: instance.name)
        }
    }
}
