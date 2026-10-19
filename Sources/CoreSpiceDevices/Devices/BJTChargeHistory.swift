import Synchronization

/// One synchronized owner for BJT accepted currents and transient-session admission.
final class BJTChargeHistory: Sendable {
    struct State: Sendable {
        var beCurrent = 0.0
        var bcCurrent = 0.0
        var active = false
        var generation: UInt64 = 0
    }
    private let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
    func begin(device: String) throws {
        try state.withLock {
            guard !$0.active else {
                throw DeviceBindingError.invalidParameterValue(device: device,
                    parameter: "transientSession", message: "BJT already belongs to an active transient session")
            }
            let (generation, overflow) = $0.generation.addingReportingOverflow(1)
            guard !overflow else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "BJT session generation overflow")
            }
            $0 = State(beCurrent: 0, bcCurrent: 0, active: true, generation: generation)
        }
    }
    func update(expectedGeneration: UInt64, device: String, _ transform: (inout State) throws -> Void) throws {
        try state.withLock {
            guard $0.active, $0.generation == expectedGeneration else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "BJT accepted history changed during commit")
            }
            let (generation, overflow) = $0.generation.addingReportingOverflow(1)
            guard !overflow else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "BJT accepted-step generation overflow")
            }
            var proposed = $0
            try transform(&proposed)
            proposed.generation = generation
            $0 = proposed
        }
    }
    func end() { state.withLock { $0.active = false } }
}
