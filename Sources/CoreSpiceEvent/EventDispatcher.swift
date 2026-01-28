import Synchronization
import Dispatch

public final class EventDispatcher: Sendable {

    private let state: Mutex<[any AnalysisObserver]>
    private let queue: DispatchQueue

    public init(observers: [any AnalysisObserver] = []) {
        state = Mutex(observers)
        queue = DispatchQueue(label: "CoreSpice.EventDispatcher", qos: .utility)
    }

    public func addObserver(_ observer: any AnalysisObserver) {
        state.withLock { $0.append(observer) }
    }

    public func emit(_ event: AnalysisEvent) {
        let observers = state.withLock { Array($0) }
        queue.async {
            for observer in observers {
                observer.onEvent(event)
            }
        }
    }
}
