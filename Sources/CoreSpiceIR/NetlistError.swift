/// Errors that can occur when building a netlist.
public enum NetlistError: Error, Sendable {
    case duplicateInstanceName(String)
    case unknownNode(String)
    case invalidParameterValue(instance: String, parameter: String, message: String)
    case missingRequiredParameter(instance: String, parameter: String)
    case portCountMismatch(instance: String, expected: Int, got: Int)
    case emptyNetlist
}
