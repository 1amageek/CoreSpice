public protocol AnalysisObserver: Sendable {
    func onEvent(_ event: AnalysisEvent)
}
