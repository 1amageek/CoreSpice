# CoreSpiceEvent Module

## Overview

CoreSpiceEvent is an event-driven observability module for circuit simulation analysis. It provides a comprehensive event system for monitoring, logging, and reacting to various stages and states during SPICE-like circuit analysis operations including DC, AC, transient, and photonic simulations.

The module follows the Observer design pattern, enabling decoupled monitoring of simulation progress, numerical solver iterations, GPU dispatches, and diagnostic information.

## Architecture

```
                    +-------------------+
                    | EventDispatcher   |
                    +-------------------+
                            |
                            | emit()
                            v
              +---------------------------+
              |   AnalysisObserver        |
              |       (Protocol)          |
              +---------------------------+
                    /           \
                   /             \
    +----------------+    +-----------------------+
    | ConsoleObserver|    | FilteringObserver     |
    +----------------+    +-----------------------+
    | CompositeObserver|  | BufferingObserver     |
    +------------------+  +-----------------------+
    | JsonLinesObserver|
    +------------------+
```

## File Structure

### Core Types

| File | Description |
|------|-------------|
| `AnalysisID.swift` | Unique identifier (UUID wrapper) for tracking individual analysis runs |
| `Timestamp.swift` | High-precision timestamp using `ContinuousClock` for elapsed time calculations |
| `AnalysisEvent.swift` | Main event enum with 16 event types covering the full analysis lifecycle |
| `AnalysisEvent+Category.swift` | Extension adding `EventCategory` classification (lifecycle, progress, sweep, newton, timeStep, gpu, metric, diagnostic) |
| `AnalysisObserver.swift` | Protocol defining the observer interface with single `onEvent(_:)` method |
| `CancellationToken.swift` | Thread-safe cancellation mechanism using `Atomic<Bool>` |
| `EventDispatcher.swift` | Central event hub managing observers and async event dispatch |

### EventInfo Types (in `EventInfo/` subdirectory)

| File | Description |
|------|-------------|
| `AnalysisType.swift` | Enum: `dc`, `ac`, `tran`, `photonic` |
| `AnalysisStatus.swift` | Enum: `completed`, `cancelled`, `failed` |
| `AnalysisStartedInfo.swift` | Analysis start event data (id, type, node/device counts) |
| `AnalysisFinishedInfo.swift` | Analysis completion data (status, wall time) |
| `ProgressInfo.swift` | Progress update (fraction 0-1, message) with validation |
| `SweepPointInfo.swift` | DC/AC sweep point start data |
| `SweepPointResultInfo.swift` | Sweep point completion (convergence, iterations) |
| `NewtonInfo.swift` | Newton iteration start data |
| `NewtonResultInfo.swift` | Newton iteration result (residual, damping, convergence) |
| `NewtonFailureInfo.swift` | Newton convergence failure details |
| `TimeStepInfo.swift` | Transient time step completion data (LTE) |
| `TimeStepRejectInfo.swift` | Rejected time step with new step size |
| `GridDimensions.swift` | 2D grid size for GPU dispatch |
| `GpuDispatchInfo.swift` | GPU kernel dispatch start data |
| `GpuDispatchResultInfo.swift` | GPU kernel completion with elapsed time |
| `MetricSampleInfo.swift` | Generic metric sample (name, value, unit) |
| `DiagnosticCode.swift` | Enum of diagnostic codes (NaN, Inf, singularity, etc.) |
| `DiagnosticInfo.swift` | Warning/error diagnostic data |

### Observer Implementations (in `Observers/` subdirectory)

| File | Description |
|------|-------------|
| `ConsoleObserver.swift` | Prints formatted event logs to stdout |
| `CompositeObserver.swift` | Aggregates multiple observers |
| `FilteringObserver.swift` | Filters events by category before forwarding |
| `BufferingObserver.swift` | Thread-safe ring buffer for event collection |
| `EventEnvelope.swift` | Codable wrapper for JSON serialization |
| `JsonLinesObserver.swift` | Writes events as JSON Lines to a file handle |

## Public API Summary

### Core Types

```swift
// Unique analysis identifier
public struct AnalysisID: Hashable, Sendable {
    public let rawValue: UUID
    public init()
}

// High-precision timestamp
public struct Timestamp: Sendable {
    public let instant: ContinuousClock.Instant
    public init()
    public func elapsed(since other: Timestamp) -> Duration
}

// Thread-safe cancellation
public final class CancellationToken: Sendable {
    public init()
    public func cancel()
    public var isCancelled: Bool { get }
}
```

### Events

```swift
public enum AnalysisEvent: Sendable {
    case analysisStarted(AnalysisStartedInfo)
    case analysisFinished(AnalysisFinishedInfo)
    case progressUpdate(ProgressInfo)
    case sweepPointStarted(SweepPointInfo)
    case sweepPointFinished(SweepPointResultInfo)
    case newtonIterationStarted(NewtonInfo)
    case newtonIterationFinished(NewtonResultInfo)
    case newtonConvergenceFailure(NewtonFailureInfo)
    case timeStepCompleted(TimeStepInfo)
    case timeStepRejected(TimeStepRejectInfo)
    case gpuDispatchStarted(GpuDispatchInfo)
    case gpuDispatchFinished(GpuDispatchResultInfo)
    case metricSample(MetricSampleInfo)
    case warning(DiagnosticInfo)
    case error(DiagnosticInfo)
}

public enum EventCategory: Sendable, Hashable {
    case lifecycle, progress, sweep, newton, timeStep, gpu, metric, diagnostic
}

extension AnalysisEvent {
    public var category: EventCategory { get }
}
```

### Observer Protocol & Dispatcher

```swift
public protocol AnalysisObserver: Sendable {
    func onEvent(_ event: AnalysisEvent)
}

public final class EventDispatcher: Sendable {
    public init(observers: [any AnalysisObserver] = [])
    public func addObserver(_ observer: any AnalysisObserver)
    public func emit(_ event: AnalysisEvent)
}
```

### Built-in Observers

```swift
// Console logging
public struct ConsoleObserver: AnalysisObserver {
    public init()
}

// Combine multiple observers
public struct CompositeObserver: AnalysisObserver {
    public init(observers: [any AnalysisObserver])
}

// Filter by category
public struct FilteringObserver: AnalysisObserver {
    public init(allowing categories: Set<EventCategory>, forwarding target: any AnalysisObserver)
}

// Ring buffer for event collection
public final class BufferingObserver: AnalysisObserver {
    public init(capacity: Int)
    public var events: [AnalysisEvent] { get }  // drains buffer
    public var count: Int { get }
}

// JSON Lines file output
public final class JsonLinesObserver: AnalysisObserver {
    public init(fileHandle: FileHandle)
}
```

## Implementation Status

### Complete Features

- [x] Full event type hierarchy for all analysis phases
- [x] Thread-safe event dispatching with `Mutex`
- [x] Thread-safe cancellation token with atomic operations
- [x] Console logging observer
- [x] Composite observer pattern
- [x] Category-based event filtering
- [x] Ring buffer observer with bounded memory
- [x] JSON Lines serialization for log files
- [x] High-precision timestamps using `ContinuousClock`
- [x] All types conform to `Sendable` for Swift concurrency safety

### Potential Future Enhancements

- [ ] `removeObserver()` method on `EventDispatcher`
- [ ] Async observer variant for Swift structured concurrency
- [ ] Event replay from JSON Lines files
- [ ] Metric aggregation observer (min/max/avg)
- [ ] OSLog-based observer for unified logging

## Code Review Notes

### Strengths

1. **Excellent Concurrency Design**: All types are `Sendable`. Uses `Mutex<T>` and `Atomic<Bool>` properly for thread safety, following modern Swift concurrency patterns.

2. **Clean Separation of Concerns**: Each file contains exactly one type (following 1-file-1-type rule). Event info types are well-separated in `EventInfo/` directory.

3. **Value Types First**: All info structs are value types. Only `CancellationToken`, `BufferingObserver`, `JsonLinesObserver`, and `EventDispatcher` are classes (where reference semantics are needed).

4. **Protocol-Oriented**: `AnalysisObserver` protocol enables extensibility without modification.

5. **Input Validation**: `ProgressInfo` uses precondition for fraction validation. `BufferingObserver` validates capacity.

6. **Efficient Ring Buffer**: Custom implementation avoids allocation overhead during event collection.

### Minor Observations

1. **EventDispatcher Observer Removal**: No public method to remove observers. Once added, observers persist for the dispatcher's lifetime. This is acceptable for many use cases but limits flexibility.

2. **JsonLinesObserver Error Handling**: Encoding errors are logged to stderr but otherwise silently ignored. Consider providing an error callback or throwing variant.

3. **EventEnvelope Timestamp**: Uses `Date().timeIntervalSince1970` rather than the event's `Timestamp` field where available. This captures serialization time rather than event time.

4. **RingBuffer Access Level**: `RingBuffer` struct is `internal` but could be `private` since it's only used by `BufferingObserver`.

5. **Duration Serialization**: `Duration` is serialized via `String(describing:)` which produces a debug description. Consider a more structured format for parsing.

### Quality Assessment

**Overall Grade: A**

The module demonstrates professional Swift design:
- Modern Swift 6 concurrency patterns
- Consistent API conventions
- Comprehensive documentation-ready type names
- No force unwraps or unsafe patterns
- Clean enum-based event modeling

The code is production-ready and well-suited for integration with circuit simulation engines.
