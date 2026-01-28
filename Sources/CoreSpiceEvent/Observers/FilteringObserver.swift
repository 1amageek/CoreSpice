public struct FilteringObserver: AnalysisObserver {

    private let allowedCategories: Set<EventCategory>
    private let target: any AnalysisObserver

    public init(
        allowing categories: Set<EventCategory>,
        forwarding target: any AnalysisObserver
    ) {
        self.allowedCategories = categories
        self.target = target
    }

    public func onEvent(_ event: AnalysisEvent) {
        guard allowedCategories.contains(event.category) else { return }
        target.onEvent(event)
    }
}
