public struct AnalysisFailureInfo: Sendable {

    public let reason: String
    public let message: String

    public init(reason: String, message: String) {
        self.reason = reason
        self.message = message
    }

    public init(error: any Error) {
        self.reason = String(describing: type(of: error))
        self.message = String(describing: error)
    }
}
