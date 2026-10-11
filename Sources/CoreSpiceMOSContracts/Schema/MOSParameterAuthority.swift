/// Identifies the owner that consumes an admitted parameter.
public enum MOSParameterAuthority: Sendable, Hashable {
    case schema
    case native(MOSParameterID)
    case parallelMultiplicity
    case initialConditionComponent(Int)
}
