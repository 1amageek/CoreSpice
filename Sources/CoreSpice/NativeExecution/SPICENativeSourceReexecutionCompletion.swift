import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR

/// Successful child observations joined exactly to the fresh source preparation that produced them.
public struct SPICENativeSourceReexecutionCompletion: Sendable {
    public enum Observation: Sendable {
        case dc(output: CompensatedValue, node: Node)
        case ac(outputs: [ComplexPair], frequencies: [Double], positiveNode: Node, referenceNode: Node?)
    }
    public let deviceName: String
    public let parameterName: String
    public let nominalValue: Double
    public let perturbedValue: Double
    public let effectiveIncrement: CompensatedValue
    public let observation: Observation
    public let completedPhase: NativeCircuitExecutionFacts
    public let preparedSource: SPICENativeSourceReexecutionRecord
    public var sourceInputIdentity: ContentDigest { preparedSource.sourceInputIdentity }
    public var configurationIdentity: ContentDigest { preparedSource.configurationIdentity }
    public var configuration: SPICEEffectiveSimulationConfiguration { preparedSource.configuration }
    public var sourceOverrides: [NetlistSourceScalarOverride] { preparedSource.sourceOverrides }
    public var osdiInstances: [String: OSDIResolvedInstance] { preparedSource.osdiInstances }
    public var preparation: NativeCircuitPreparationRecord { preparedSource.preparation }
    public var selectedDiodeModels: [String: String] { preparedSource.selectedDiodeModels }
    public var selectedModelOrigins: [String: ParsedModelOrigin] { preparedSource.selectedModelOrigins }
    public var evaluationProvenance: NetlistEvaluationProvenance { preparedSource.evaluationProvenance }

    internal init(deviceName: String, parameterName: String, nominalValue: Double, perturbedValue: Double,
                  effectiveIncrement: CompensatedValue, observation: Observation,
                  completedPhase: NativeCircuitExecutionFacts, preparedSource: SPICENativeSourceReexecutionRecord) {
        self.deviceName = deviceName; self.parameterName = parameterName; self.nominalValue = nominalValue
        self.perturbedValue = perturbedValue; self.effectiveIncrement = effectiveIncrement; self.observation = observation
        self.completedPhase = completedPhase; self.preparedSource = preparedSource
    }
}
