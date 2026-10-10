/// Complete immutable preparation conditions, independent of model parameter defaults.
public struct MOSPreparationConditions: Sendable, Hashable {
    public let ambientKelvin: Double
    public let nominalKelvin: Double
    public let analysisCapabilities: MOSAnalysisCapabilities
    public let maximumStressIterations: UInt32

    public init(ambientKelvin: Double, nominalKelvin: Double,
                analysisCapabilities: MOSAnalysisCapabilities, maximumStressIterations: UInt32)
        throws(MOSPreparationFailure) {
        guard ambientKelvin.isFinite, ambientKelvin > 0, nominalKelvin.isFinite, nominalKelvin > 0,
              !analysisCapabilities.isEmpty,
              analysisCapabilities.subtracting(.all).isEmpty,
              maximumStressIterations > 0 else { throw .invalidConditions }
        self.ambientKelvin = ambientKelvin; self.nominalKelvin = nominalKelvin
        self.analysisCapabilities = analysisCapabilities; self.maximumStressIterations = maximumStressIterations
    }
}
