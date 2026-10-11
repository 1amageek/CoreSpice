import CoreSpiceMOSContracts

/// One evaluated input owned by the exact release schema and parameter role.
public struct BSIM45Parameter: Sendable {
    public let id: MOSParameterID
    public let kind: MOSParameterKind
    public let value: Double
    public init(id: MOSParameterID, kind: MOSParameterKind, value: Double) {
        self.id = id; self.kind = kind; self.value = value
    }
}
