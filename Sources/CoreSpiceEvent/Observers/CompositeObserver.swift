public struct CompositeObserver: AnalysisObserver {

    private let observers: [any AnalysisObserver]

    public init(observers: [any AnalysisObserver]) {
        self.observers = observers
    }

    public func onEvent(_ event: AnalysisEvent) {
        for observer in observers {
            observer.onEvent(event)
        }
    }
}
