import Testing
import Foundation
import Synchronization
@testable import CoreSpiceEvent

@Suite("Event Dispatcher Tests")
struct EventDispatcherTests {

    // MARK: - Test Observer

    /// A test observer that records events in order.
    final class RecordingObserver: AnalysisObserver, Sendable {
        private let storage = Mutex<[AnalysisEvent]>([])

        var events: [AnalysisEvent] {
            storage.withLock { $0 }
        }

        func onEvent(_ event: AnalysisEvent) {
            storage.withLock { $0.append(event) }
        }
    }

    // MARK: - Basic Tests

    @Test("Dispatcher emits events to observer")
    func basicEmit() async {
        let observer = RecordingObserver()
        let dispatcher = EventDispatcher(observers: [observer])

        let id = AnalysisID()
        await dispatcher.emit(.analysisStarted(AnalysisStartedInfo(
            id: id,
            type: .dc,
            timestamp: Timestamp(),
            nodeCount: 10,
            deviceCount: 5
        )))

        #expect(observer.events.count == 1)
    }

    @Test("Dispatcher supports multiple observers")
    func multipleObservers() async {
        let observer1 = RecordingObserver()
        let observer2 = RecordingObserver()
        let dispatcher = EventDispatcher(observers: [observer1, observer2])

        let id = AnalysisID()
        await dispatcher.emit(.analysisStarted(AnalysisStartedInfo(
            id: id,
            type: .dc,
            timestamp: Timestamp(),
            nodeCount: 10,
            deviceCount: 5
        )))

        #expect(observer1.events.count == 1)
        #expect(observer2.events.count == 1)
    }

    @Test("Can add observer dynamically")
    func addObserver() async {
        let observer = RecordingObserver()
        let dispatcher = EventDispatcher()

        await dispatcher.addObserver(observer)

        let id = AnalysisID()
        await dispatcher.emit(.analysisStarted(AnalysisStartedInfo(
            id: id,
            type: .dc,
            timestamp: Timestamp(),
            nodeCount: 10,
            deviceCount: 5
        )))

        #expect(observer.events.count == 1)
    }

    // MARK: - Event Ordering Tests

    @Test("Events are processed in emission order within single task")
    func eventOrdering() async {
        let observer = RecordingObserver()
        let dispatcher = EventDispatcher(observers: [observer])
        let id = AnalysisID()

        // Emit a sequence of events
        await dispatcher.emit(.analysisStarted(AnalysisStartedInfo(
            id: id,
            type: .dc,
            timestamp: Timestamp(),
            nodeCount: 10,
            deviceCount: 5
        )))

        for i in 0..<5 {
            await dispatcher.emit(.progressUpdate(ProgressInfo(
                id: id,
                fraction: Double(i) / 5.0,
                message: "Step \(i)"
            )))
        }

        await dispatcher.emit(.analysisFinished(AnalysisFinishedInfo(
            id: id,
            type: .dc,
            status: .completed,
            timestamp: Timestamp(),
            wallTime: .seconds(1)
        )))

        // Verify order: started, 5 progress updates, finished
        #expect(observer.events.count == 7)

        // First event should be analysisStarted
        if case .analysisStarted = observer.events[0] {
            // OK
        } else {
            Issue.record("First event should be analysisStarted")
        }

        // Events 1-5 should be progressUpdate
        for i in 1...5 {
            if case .progressUpdate(let info) = observer.events[i] {
                #expect(info.message == "Step \(i - 1)")
            } else {
                Issue.record("Event \(i) should be progressUpdate")
            }
        }

        // Last event should be analysisFinished
        if case .analysisFinished = observer.events[6] {
            // OK
        } else {
            Issue.record("Last event should be analysisFinished")
        }
    }

    @Test("Finished event envelope carries structured failure details")
    func failedFinishedEnvelopeIncludesFailure() {
        let id = AnalysisID()
        let envelope = EventEnvelope(event: .analysisFinished(AnalysisFinishedInfo(
            id: id,
            type: .ac,
            status: .failed,
            timestamp: Timestamp(),
            wallTime: .seconds(1),
            failure: AnalysisFailureInfo(
                reason: "nonFiniteSolution",
                message: "AC solution contains non-finite values",
                stage: "ac",
                component: "complexSolver",
                suggestedActions: ["inspect_operating_point"],
                metadata: ["frequency": "1000.0"]
            )
        )))

        #expect(envelope.payload["status"] == "failed")
        #expect(envelope.payload["failureReason"] == "nonFiniteSolution")
        #expect(envelope.payload["failureMessage"] == "AC solution contains non-finite values")
        #expect(envelope.payload["failureSeverity"] == "error")
        #expect(envelope.payload["failureStage"] == "ac")
        #expect(envelope.payload["failureComponent"] == "complexSolver")
        #expect(envelope.payload["failureSuggestedActions"] == "inspect_operating_point")
        #expect(envelope.payload["failure.frequency"] == "1000.0")
    }

    @Test("Sequential await calls preserve order")
    func sequentialAwaitOrder() async {
        let observer = RecordingObserver()
        let dispatcher = EventDispatcher(observers: [observer])
        let id = AnalysisID()

        // Simulate typical analysis event sequence
        await dispatcher.emit(.newtonIterationStarted(NewtonInfo(
            id: id,
            iteration: 0,
            maxIterations: 10
        )))

        await dispatcher.emit(.newtonIterationFinished(NewtonResultInfo(
            id: id,
            iteration: 0,
            residualNorm: 1e-10,
            damping: 1.0,
            converged: false
        )))

        await dispatcher.emit(.newtonIterationStarted(NewtonInfo(
            id: id,
            iteration: 1,
            maxIterations: 10
        )))

        await dispatcher.emit(.newtonIterationFinished(NewtonResultInfo(
            id: id,
            iteration: 1,
            residualNorm: 1e-12,
            damping: 1.0,
            converged: true
        )))

        #expect(observer.events.count == 4)

        // Verify alternating started/finished pattern
        if case .newtonIterationStarted(let info) = observer.events[0] {
            #expect(info.iteration == 0)
        } else {
            Issue.record("Event 0 should be newtonIterationStarted")
        }

        if case .newtonIterationFinished(let info) = observer.events[1] {
            #expect(info.iteration == 0)
        } else {
            Issue.record("Event 1 should be newtonIterationFinished")
        }

        if case .newtonIterationStarted(let info) = observer.events[2] {
            #expect(info.iteration == 1)
        } else {
            Issue.record("Event 2 should be newtonIterationStarted")
        }

        if case .newtonIterationFinished(let info) = observer.events[3] {
            #expect(info.iteration == 1)
            #expect(info.converged == true)
        } else {
            Issue.record("Event 3 should be newtonIterationFinished")
        }
    }
}
