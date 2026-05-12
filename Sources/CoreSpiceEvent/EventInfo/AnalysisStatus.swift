public enum AnalysisStatus: String, Sendable, Codable {
    case completed
    case cancelled
    case failed

    public func failureInfo(for error: any Error) -> AnalysisFailureInfo? {
        switch self {
        case .failed:
            return AnalysisFailureInfo(error: error)
        case .completed, .cancelled:
            return nil
        }
    }
}
