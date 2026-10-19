import CoreSpiceMOSContracts

/// One explicit source-unit scalar replacement for a concrete hierarchical instance.
public struct NetlistSourceScalarOverride: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case instance, model }
    public let instanceName: String
    public let parameterName: String
    public let role: Role
    public let value: Double

    public init(instanceName: String, parameterName: String, role: Role = .instance,
                value: Double) throws(MOSResolutionFailure) {
        guard !instanceName.isEmpty, !parameterName.isEmpty, value.isFinite else {
            throw .invalidRequest
        }
        self.instanceName = instanceName
        self.parameterName = parameterName
        self.role = role
        self.value = value
    }
}
