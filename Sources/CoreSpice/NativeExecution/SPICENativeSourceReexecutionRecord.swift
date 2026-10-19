import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceParsedIR
import CoreSpiceOSDIContracts

/// Exact fresh scalar configuration and actual native topology consumed by one child solve.
public struct SPICENativeSourceReexecutionRecord: Sendable {
    public let selectedModelOrigins: [String: ParsedModelOrigin]
    public let osdiInstances: [String: OSDIResolvedInstance]
    public let selectedDiodeModels: [String: String]
    public let sourceInputIdentity: ContentDigest
    public let configurationIdentity: ContentDigest
    public let configuration: SPICEEffectiveSimulationConfiguration
    public let sourceOverrides: [NetlistSourceScalarOverride]
    public let evaluationProvenance: NetlistEvaluationProvenance
    private let reservation: SPICESourceStorageReservation
    public let preparation: NativeCircuitPreparationRecord

    internal init(prepared: SPICENativeSimulationRecord) throws {
        let provenance = prepared.input.lowered.evaluationProvenance
        try prepared.input.resources.charge(.retainedElements, units: UInt64(provenance.sourceScalars.count))
        let provenanceBytes = try provenance.retainedPayloadByteCount()
        try prepared.input.resources.charge(.projectedBytes, units: provenanceBytes)
        let copiedReceipts = prepared.circuitPreparation.osdiLifetime == nil ? 0
            : 3 * MemoryLayout<SPICESourceStorageReservation>.stride
        let bytes = try NativeCircuitExecution.capacitySum(prepared.input.retainedConfigurationBytes,
            NativeCircuitExecution.capacitySum(provenanceBytes, UInt64(copiedReceipts)))
        reservation = try prepared.input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        var diodeModels: [String: String] = [:]
        diodeModels.reserveCapacity(prepared.diodePreparationReceipts.count)
        for receipt in prepared.diodePreparationReceipts {
            let resolved = receipt.identity.resolved
            diodeModels[resolved.instance] = try prepared.input.lowered.compiled.modelName(for: resolved)
        }
        var origins: [String: ParsedModelOrigin] = [:]
        origins.reserveCapacity(prepared.mosPreparationReceipts.count + prepared.diodePreparationReceipts.count)
        for receipt in prepared.mosPreparationReceipts {
            if let origin = try prepared.input.lowered.compiled.modelOrigin(for: receipt.identity.resolved) {
                origins[receipt.identity.resolved.instance] = origin
            }
        }
        for receipt in prepared.diodePreparationReceipts {
            if let origin = try prepared.input.lowered.compiled.modelOrigin(for: receipt.identity.resolved) {
                origins[receipt.identity.resolved.instance] = origin
            }
        }
        selectedModelOrigins = origins
        osdiInstances = prepared.input.request.osdiInstances
        selectedDiodeModels = diodeModels
        sourceInputIdentity = prepared.input.sourceInputIdentity
        configurationIdentity = prepared.configurationIdentity
        configuration = prepared.input.configuration
        sourceOverrides = prepared.input.lowered.compiled.sourceOverrides
        evaluationProvenance = prepared.input.lowered.evaluationProvenance
        preparation = try prepared.circuitPreparation.valueEvidence()
    }
}
