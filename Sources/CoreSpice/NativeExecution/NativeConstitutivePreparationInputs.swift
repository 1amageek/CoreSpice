import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Explicit source snapshot policy; Native supplies the actual request control.
public struct NativeConstitutivePreparationInputs: Sendable {
    package let preparer: any OSDIPrecisionSessionPreparing
    package let semanticProfile: ContentDigest
    package let options: OSDIPrecisionOptions
    package let simulationParameters: [OSDISimulationParameter]?
    public init(preparer: OSDINativePrecisionSessionPreparer, semanticProfile: ContentDigest,
        options: OSDIPrecisionOptions, simulationParameters: [OSDISimulationParameter]? = nil) {
        self.preparer = preparer; self.semanticProfile = semanticProfile
        self.options = options; self.simulationParameters = simulationParameters
    }
    /// Trusted package fixture seam; external callers cannot substitute snapshot authority.
    package init(preparer: any OSDIPrecisionSessionPreparing, semanticProfile: ContentDigest,
        options: OSDIPrecisionOptions, simulationParameters: [OSDISimulationParameter]? = nil) {
        self.preparer = preparer; self.semanticProfile = semanticProfile
        self.options = options; self.simulationParameters = simulationParameters
    }
}
