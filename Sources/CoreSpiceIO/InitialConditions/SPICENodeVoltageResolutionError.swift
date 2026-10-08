/// Actual semantic/evaluation failures; bounded diagnostics avoid copied input payloads.
public enum SPICENodeVoltageResolutionError: Error, Sendable {
    case unknownNode(String)
    case nonfiniteValue(nodeName: String, value: Double)
    case nonzeroGround
    case evaluation(nodeName: String, cause: any Error)
    case boundedUnknownNode(assignmentIndex: Int)
    case boundedNonfiniteValue(assignmentIndex: Int)
    case ambiguousBinding(assignmentIndex: Int)
    case ambiguousCircuitName(assignmentIndex: Int)
    case unsupportedCapability(Capability)
    case resource(cause: any Error)

    public enum Capability: Sendable, Equatable {
        case nonliteralExpression, unicodeNodeName, nonscalarValue
    }
}
