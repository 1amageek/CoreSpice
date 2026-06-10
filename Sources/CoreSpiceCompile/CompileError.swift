/// Errors that can occur during circuit compilation.
public enum CompileError: Error, Sendable {
    case unknownDeviceType(String)
    case bindingFailed(instance: String, reason: String)
    case emptyCircuit
    case singularMatrix
    case incompatibleStructure(String)
    case vectorDimensionMismatch(vector: String, expected: Int, actual: Int)
}
