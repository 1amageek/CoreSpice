import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts
import CoreSpiceParsedIR

/// Copyable evidence and rerun inputs, without executable device owners.
public struct SPICENativeSimulationRecord: Sendable {
    public let input: PreparedSPICESimulation
    public let circuitPreparation: NativeCircuitPreparationRecord
    public var plan: ExecutionPlan { circuitPreparation.plan }
    public var limits: SPICENativeExecutionLimits { circuitPreparation.limits }
    public let configurationIdentity: ContentDigest
    public let algorithmIdentity: String
    public let solverIdentity: String
    public let precisionConfigurationBinding: NativePrecisionConfigurationBinding?
    public let precisionConfigurationFacts: NativePrecisionConfigurationFacts?
    public var osdiRuntimeInputs: SPICEOSDIRuntimeInputs? { circuitPreparation.osdiRuntimeInputs }
    public var osdiPreparationRecords: [NativeOSDIPreparationRecord] { circuitPreparation.osdiPreparationRecords }
    public var diodePreparationReceipts: [DiodePreparationReceipt] { circuitPreparation.diodePreparationReceipts }
    public var mosPreparationReceipts: [MOSPreparationReceipt] { circuitPreparation.mosPreparationReceipts }
    package var compileCapacity: UInt64 { circuitPreparation.compileCapacity }

    internal init(input: PreparedSPICESimulation, circuitPreparation: NativeCircuitPreparationRecord,
                  configurationIdentity: ContentDigest, precisionConfigurationBinding: NativePrecisionConfigurationBinding? = nil,
                  precisionConfigurationFacts: NativePrecisionConfigurationFacts? = nil) {
        self.input = input; self.circuitPreparation = circuitPreparation
        self.configurationIdentity = configurationIdentity
        self.precisionConfigurationBinding = precisionConfigurationBinding; self.precisionConfigurationFacts = precisionConfigurationFacts
        algorithmIdentity = Self.algorithmIdentity(for: circuitPreparation, analysis: input.configuration.analysis)
        solverIdentity = SparseLUSolver.implementationIdentity
    }

    internal static func algorithmIdentity(for record: NativeCircuitPreparationRecord,
                                           analysis: SPICEEffectiveSimulationConfiguration.Analysis? = nil) -> String {
        if case .network? = analysis {
            return record.osdiPreparationRecords.isEmpty ? "CoreSpice.NativeCPU.network.voltage-controlled.v1"
                : "CoreSpice.NativeCPU.OSDI.network.voltage-controlled.v1"
        }
        if record.osdiPreparationRecords.isEmpty { return "CoreSpice.NativeCPU.source-analyses.v3" }
        return record.osdiRuntimeInputs?.transientPrecision == nil
            ? "CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.v2"
            : "CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3"
    }

    internal static func configurationDomain(for record: NativeCircuitPreparationRecord) -> String {
        if record.osdiPreparationRecords.isEmpty { return "CoreSpice.native-configuration.v3.diode" }
        return record.osdiRuntimeInputs?.transientPrecision == nil
            ? "CoreSpice.native-configuration.v4.osdi-analysis"
            : "CoreSpice.native-configuration.v5.osdi-precision"
    }
}
