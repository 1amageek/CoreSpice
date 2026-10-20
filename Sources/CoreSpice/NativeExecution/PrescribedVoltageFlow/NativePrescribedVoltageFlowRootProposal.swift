import CoreSpiceCompile
import CoreSpiceDevices

/// Untrusted finite coordinate box, center and sparse numerical preconditioner.
public struct NativePrescribedVoltageFlowRootProposal: Sendable {
    public let coordinates: [CompensatedEnclosure]
    public let center: [CompensatedValue]
    public let inverse: SparseStructure
    public let inverseValues: [Double]
    public init(coordinates: [CompensatedEnclosure], center: [CompensatedValue],
        inverse: SparseStructure, inverseValues: [Double]) {
        self.coordinates = coordinates; self.center = center
        self.inverse = inverse; self.inverseValues = inverseValues
    }
}
