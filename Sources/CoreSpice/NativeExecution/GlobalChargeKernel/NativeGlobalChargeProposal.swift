import CoreSpiceAnalysis
import CoreSpiceCompile

/// Proposed coefficients and rank witnesses; none have source authority until checked.
package struct NativeGlobalChargeProposal: Sendable {
    package let nullRows: ExactRowAlgebra.Rows
    package let anchors: [NativeGlobalChargeAnchor]
    package let inverse: SparseStructure
    package let inverseValues: [Double]
    package init(nullRows: ExactRowAlgebra.Rows, anchors: [NativeGlobalChargeAnchor],
        inverse: SparseStructure, inverseValues: [Double]) {
        self.nullRows = nullRows; self.anchors = anchors
        self.inverse = inverse; self.inverseValues = inverseValues
    }
}
