/// Event dispatcher using Swift Concurrency.
///
/// This actor manages analysis observers and dispatches events to them.
/// Events are processed in order within a single task due to actor
/// serialization and the `await` requirement on callers.
public actor EventDispatcher {

    private var observers: [any AnalysisObserver]

    public init(observers: [any AnalysisObserver] = []) {
        self.observers = observers
    }

    public func addObserver(_ observer: any AnalysisObserver) {
        observers.append(observer)
    }

    /// Dispatch an event to all registered observers.
    ///
    /// Events are processed synchronously and in order within a single
    /// calling task. The `await` requirement ensures that callers
    /// wait for event dispatch to complete before continuing.
    public func emit(_ event: AnalysisEvent) {
        for observer in observers {
            observer.onEvent(event)
        }
    }
}
