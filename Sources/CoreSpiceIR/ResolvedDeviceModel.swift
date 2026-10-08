/// Resolved model provenance, separate from placed-instance parameters.
public struct ResolvedDeviceModel: Sendable {
    public let declarationID: String?
    public let name: String
    public let typeName: String
    public let parameters: [String: ParameterValue]

    public init(name: String, typeName: String, parameters: [String: ParameterValue], declarationID: String? = nil) {
        self.declarationID = declarationID
        self.name = name
        self.typeName = typeName
        self.parameters = parameters
    }
}
