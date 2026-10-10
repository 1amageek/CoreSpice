import CoreSpiceMOSContracts

/// Snapshot-bound semantic slot; identical programs in different slots remain distinct.
public struct NetlistScalarSlot: Sendable, Hashable {
    public let address: NetlistScalarAddress
    public let program: MOSProgramID
    let identity: MOSIdentitySpace
    let index: Int
}
