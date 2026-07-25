/// Errors that can occur when binding a device instance.
public enum DeviceBindingError: Error, Sendable {
    /// A required parameter was not provided and has no default.
    case missingParameter(device: String, parameter: String)
    /// A parameter has an unexpected type.
    case invalidParameterType(device: String, parameter: String, expected: String)
    /// The instance has the wrong number of connected ports.
    case portCountMismatch(device: String, expected: Int, got: Int)
    /// A parameter value is out of range or otherwise invalid.
    case invalidParameterValue(device: String, parameter: String, message: String)
    /// The compiled topology does not contain a branch required by the device.
    case missingBranchVariable(device: String, ownedIndex: Int)
    /// Two devices attempted to claim the same canonical branch.
    case duplicateBranchOwnership(device: String, branchID: Int)
}
