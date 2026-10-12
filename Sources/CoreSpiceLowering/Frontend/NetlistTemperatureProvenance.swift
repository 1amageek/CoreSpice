/// Source ownership remains in CompiledNetlist; indices identify actual ordered controls.
public struct NetlistTemperatureProvenance: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        case callerDefault
        case callerOverride
        case sourceControl(Int)
        public var description: String {
            switch self {
            case .callerDefault: "caller-default-v1"
            case .callerOverride: "caller-override"
            case .sourceControl: "source"
            }
        }
    }
    public let ambient: Origin
    public let nominal: Origin
}
