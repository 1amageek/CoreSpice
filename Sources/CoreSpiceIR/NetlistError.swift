/// Errors that can occur when building a netlist.
public enum NetlistError: Error, Sendable {
    case duplicateInstanceName(String)
    case invalidParameterValue(instance: String, parameter: String, message: String)
    case emptyNetlist
}
