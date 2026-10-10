import CoreSpiceMOSContracts

/// Sole model and normalized instance-value authority for a canonical MOS instance.
public enum MOSInstanceStage: Sendable, Hashable {
    case resolved(ResolvedMOSInstance)
    case prepared(MOSPreparationReceipt)
}
