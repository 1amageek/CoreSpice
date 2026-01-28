public struct DiagnosticInfo: Sendable {

    public let id: AnalysisID
    public let code: DiagnosticCode
    public let message: String
    public let timestamp: Timestamp

    public init(
        id: AnalysisID,
        code: DiagnosticCode,
        message: String,
        timestamp: Timestamp
    ) {
        self.id = id
        self.code = code
        self.message = message
        self.timestamp = timestamp
    }
}
