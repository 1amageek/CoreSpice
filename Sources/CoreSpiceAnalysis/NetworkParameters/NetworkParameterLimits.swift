/// Explicit caller policy for a complete fixed-bias network run.
public struct NetworkParameterLimits: Sendable {
    public let maximumPorts: Int
    public let maximumFrequencyPoints: Int
    public let maximumResultScalars: Int
    public let maximumTemporaryBytes: Int
    public let residualTolerance: Double
    public let executionLimits: TransientExecutionLimits

    public init(maximumPorts: Int, maximumFrequencyPoints: Int, maximumResultScalars: Int,
                maximumTemporaryBytes: Int, residualTolerance: Double,
                executionLimits: TransientExecutionLimits) {
        self.maximumPorts = maximumPorts
        self.maximumFrequencyPoints = maximumFrequencyPoints
        self.maximumResultScalars = maximumResultScalars
        self.maximumTemporaryBytes = maximumTemporaryBytes
        self.residualTolerance = residualTolerance
        self.executionLimits = executionLimits
    }

    public func validate() throws {
        guard maximumPorts > 0, maximumFrequencyPoints > 0, maximumResultScalars > 0,
              maximumTemporaryBytes > 0, residualTolerance.isFinite,
              residualTolerance > 0, residualTolerance < 1 else {
            throw NetworkParameterError.invalidConfiguration("Invalid network resource or residual limits")
        }
        try executionLimits.validate()
    }
}
