import Synchronization

/// Exclusive accepted-coordinate and derivative history for one behavioral capacitor run.
final class BehavioralCapacitorHistory: Sendable {
    struct State: Sendable {
        var active = false
        var coordinate = 0.0
        var derivative = 0.0
        var capacitance: Double?
        var time = 0.0
        var generation: UInt64 = 0
    }
    private let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
    func begin(coordinate: Double, capacitance: Double? = nil, device: String) throws {
        try validate(coordinate: coordinate, derivative: 0, capacitance: capacitance, time: 0, device: device)
        try state.withLock {
            guard !$0.active else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "Capacitor already belongs to an active transient session")
            }
            let (generation, overflow) = $0.generation.addingReportingOverflow(1)
            guard !overflow else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "Capacitor session generation overflow")
            }
            $0 = State(active: true, coordinate: coordinate, capacitance: capacitance, generation: generation)
        }
    }
    func commit(coordinate: Double, derivative: Double, capacitance: Double? = nil,
        time: Double, generation: UInt64, device: String) throws {
        try validate(coordinate: coordinate, derivative: derivative, capacitance: capacitance, time: time, device: device)
        try state.withLock {
            guard $0.active, $0.generation == generation, ($0.capacitance == nil) == (capacitance == nil) else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "Capacitor accepted history changed during commit")
            }
            let (next, overflow) = generation.addingReportingOverflow(1)
            guard !overflow else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                    message: "Capacitor accepted-step generation overflow")
            }
            $0.coordinate = coordinate; $0.derivative = derivative; $0.capacitance = capacitance
            $0.time = time; $0.generation = next
        }
    }
    func end() { state.withLock { $0.active = false } }
    private func validate(coordinate: Double, derivative: Double, capacitance: Double?, time: Double,
        device: String) throws {
        guard coordinate.isFinite, derivative.isFinite, time.isFinite,
              capacitance.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw DeviceBindingError.invalidParameterValue(device: device, parameter: "transientSession",
                message: "Capacitor accepted coordinate, derivative, coefficient and time must be valid")
        }
    }
}
