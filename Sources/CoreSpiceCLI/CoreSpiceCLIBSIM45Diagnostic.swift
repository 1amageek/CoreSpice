import CoreSpiceCompactModels

/// Host serialization of the original diagnostic; portable owner has no Codable dependency.
public struct CoreSpiceCLIBSIM45Diagnostic: Codable, Sendable, Hashable {
    public let code: UInt32
    public let role: Int32
    public let parameterID: Int32
    public let sourceSite: UInt32
    public let value: Double
    public let text: String
    init(_ value: BSIM45Diagnostic) {
        code = value.code; role = value.role; parameterID = value.parameterID
        sourceSite = value.sourceSite; self.value = value.value; text = value.text
    }
}
