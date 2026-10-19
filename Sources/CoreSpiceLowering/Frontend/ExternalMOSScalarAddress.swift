import CoreSpiceMOSContracts

/// Address in the actual ordered source programs, never a reparsed parameter name.
public enum ExternalMOSScalarAddress: Sendable, Hashable {
    case instance(index: Int)
    case model(declaration: MOSDeclarationID, index: Int)
    case modelOverride(index: Int)
}
