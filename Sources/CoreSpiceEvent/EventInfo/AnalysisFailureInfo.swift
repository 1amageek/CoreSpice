public struct AnalysisFailureInfo: Sendable {

    public let reason: String
    public let message: String
    public let stage: String?
    public let severity: String
    public let component: String?
    public let suggestedActions: [String]
    public let metadata: [String: String]

    public init(
        reason: String,
        message: String,
        stage: String? = nil,
        severity: String = "error",
        component: String? = nil,
        suggestedActions: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.reason = reason
        self.message = message
        self.stage = stage
        self.severity = severity
        self.component = component
        self.suggestedActions = suggestedActions
        self.metadata = metadata
    }

    public init(error: any Error) {
        self.reason = String(describing: type(of: error))
        self.message = String(describing: error)
        self.stage = nil
        self.severity = "error"
        self.component = nil
        self.suggestedActions = []
        self.metadata = [:]
    }
}
