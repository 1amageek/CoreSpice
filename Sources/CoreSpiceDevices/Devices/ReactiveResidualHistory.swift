import Synchronization

/// Run-owned accepted derivative history; trials only copy a snapshot.
final class ReactiveResidualHistory: Sendable {
    struct State: Sendable {
        var ordinary = 0.0
        var center = CompensatedValue.zero
        var radius = 0.0
        var active = false

        var enclosure: CompensatedEnclosure {
            get throws { try CompensatedEnclosure(center: center, radius: radius) }
        }
    }

    private let storage = Mutex(State())

    var snapshot: State { storage.withLock { $0 } }

    func update(_ body: (inout State) throws -> Void) rethrows {
        try storage.withLock { try body(&$0) }
    }

    func begin(device: String) throws {
        try storage.withLock { state in
            guard !state.active else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "A transient session is already active")
            }
            state = State(active: true)
        }
    }

    func end() { storage.withLock { $0 = State() } }
}
