import Synchronization

public final class BufferingObserver: AnalysisObserver {

    private let state: Mutex<RingBuffer>

    public init(capacity: Int) {
        precondition(capacity > 0, "BufferingObserver capacity must be positive")
        state = Mutex(RingBuffer(capacity: capacity))
    }

    public func onEvent(_ event: AnalysisEvent) {
        state.withLock { $0.append(event) }
    }

    public var events: [AnalysisEvent] {
        state.withLock { $0.drain() }
    }

    public var count: Int {
        state.withLock { $0.count }
    }
}

struct RingBuffer: Sendable {

    private var storage: [AnalysisEvent?]
    private var writeIndex: Int
    private(set) var count: Int
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }

    mutating func append(_ event: AnalysisEvent) {
        storage[writeIndex] = event
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity {
            count += 1
        }
    }

    mutating func drain() -> [AnalysisEvent] {
        guard count > 0 else { return [] }

        var result: [AnalysisEvent] = []
        result.reserveCapacity(count)

        let startIndex: Int
        if count < capacity {
            startIndex = 0
        } else {
            startIndex = writeIndex
        }

        for i in 0..<count {
            let index = (startIndex + i) % capacity
            if let event = storage[index] {
                result.append(event)
            }
        }

        // Reset
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0

        return result
    }
}
