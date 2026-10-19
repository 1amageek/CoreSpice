import Synchronization

/// Fixed-capacity accepted history; trial evaluation never publishes state.
internal final class DiodeTransientHistory: Sendable {
    struct Accepted: Sendable { let charge: Double; let current: Double; let time: Double }
    // Logical fixed object payload plus the native Swift object header; not allocator RSS.
    static let retainedCapacityBytes = MemoryLayout<Mutex<Accepted?>>.stride + 2 * MemoryLayout<Int>.stride
    private let accepted = Mutex<Accepted?>(nil)

    func begin(charge: Double) throws(DiodeNumericalFailure) {
        try accepted.withLock { (value: inout Accepted?) throws(DiodeNumericalFailure) in
            guard value == nil else { throw .transientSessionAlreadyActive }
            guard charge.isFinite else { throw .nonfiniteEvaluation }
            value = Accepted(charge: charge, current: 0, time: 0)
        }
    }
    func end() { accepted.withLock { $0 = nil } }
    func trial(charge: Double, capacitance: Double, integration: IntegrationState) throws(DiodeNumericalFailure) -> SIMD2<Double> {
        try accepted.withLock { (value: inout Accepted?) throws(DiodeNumericalFailure) in
            guard let value else { throw .transientSessionRequired }
            return try evaluate(charge: charge, capacitance: capacitance, integration: integration, previous: value)
        }
    }
    func commit(charge: Double, capacitance: Double, integration: IntegrationState) throws(DiodeNumericalFailure) {
        try accepted.withLock { (value: inout Accepted?) throws(DiodeNumericalFailure) in
            guard let previous = value else { throw .transientSessionRequired }
            let evaluation = try evaluate(charge: charge, capacitance: capacitance, integration: integration, previous: previous)
            value = Accepted(charge: charge, current: evaluation[1], time: integration.currentTime)
        }
    }
    private func evaluate(charge: Double, capacitance: Double, integration: IntegrationState,
                          previous: Accepted) throws(DiodeNumericalFailure) -> SIMD2<Double> {
        let dt = integration.timeStep, time = integration.currentTime, coefficient = integration.coefficient
        guard dt.isFinite, dt > 0, time.isFinite, time > previous.time, coefficient.isFinite,
              abs((time - previous.time) - dt) <= max(abs(time), dt) * 64 * Double.ulpOfOne else {
            throw .invalidIntegration
        }
        let current: Double
        switch integration.method {
        case .backwardEuler: current = coefficient * (charge - previous.charge)
        case .trapezoidal: current = coefficient * (charge - previous.charge) - previous.current
        }
        let conductance = coefficient * capacitance
        guard charge.isFinite, capacitance.isFinite, capacitance >= 0,
              current.isFinite, conductance.isFinite else { throw .nonfiniteEvaluation }
        return SIMD2(conductance, current)
    }
}
