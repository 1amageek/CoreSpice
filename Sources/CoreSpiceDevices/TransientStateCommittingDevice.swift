import CoreSpiceIR
import Synchronization

public protocol TransientStateCommittingDevice: BoundDevice {
    func commitTransientStep(state: SolutionState, integration: IntegrationState)
}

public final class TransientCapacitanceStore: Sendable {
    private let currents: Mutex<[String: Double]>

    public init() {
        currents = Mutex([:])
    }

    public func stamp(
        key: String,
        into stamper: inout MatrixStamper,
        node1: Int?,
        node2: Int?,
        capacitance: Double,
        state: SolutionState,
        integration: IntegrationState
    ) {
        guard capacitance > 0 else { return }
        let geq = integration.coefficient * capacitance
        let v1 = node1.map { state.previousValue(at: $0) } ?? 0.0
        let v2 = node2.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = v1 - v2

        let ieq: Double
        switch integration.method {
        case .backwardEuler:
            ieq = geq * vPrev
        case .trapezoidal:
            let iCapPrev = currents.withLock { $0[key] ?? 0.0 }
            ieq = geq * vPrev + iCapPrev
        }

        stampConductance(into: &stamper, node1: node1, node2: node2, value: geq)
        stampCurrent(into: &stamper, node1: node1, node2: node2, value: ieq)
    }

    public func commit(
        key: String,
        node1: Int?,
        node2: Int?,
        capacitance: Double,
        state: SolutionState,
        integration: IntegrationState
    ) {
        guard capacitance > 0 else {
            currents.withLock { $0[key] = 0.0 }
            return
        }

        let v1 = node1.map { state.value(at: $0) } ?? 0.0
        let v2 = node2.map { state.value(at: $0) } ?? 0.0
        let v = v1 - v2
        let vPrev1 = node1.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev2 = node2.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = vPrev1 - vPrev2

        let newCurrent: Double
        switch integration.method {
        case .backwardEuler:
            newCurrent = (capacitance / integration.timeStep) * (v - vPrev)
        case .trapezoidal:
            let geq = integration.coefficient * capacitance
            let iCapPrev = currents.withLock { $0[key] ?? 0.0 }
            newCurrent = geq * (v - vPrev) - iCapPrev
        }
        currents.withLock { $0[key] = newCurrent }
    }

    private func stampConductance(
        into stamper: inout MatrixStamper,
        node1: Int?,
        node2: Int?,
        value: Double
    ) {
        if let n1 = node1 {
            stamper.stampMatrix(n1, n1, value)
        }
        if let n2 = node2 {
            stamper.stampMatrix(n2, n2, value)
        }
        if let n1 = node1, let n2 = node2 {
            stamper.stampMatrix(n1, n2, -value)
            stamper.stampMatrix(n2, n1, -value)
        }
    }

    private func stampCurrent(
        into stamper: inout MatrixStamper,
        node1: Int?,
        node2: Int?,
        value: Double
    ) {
        if let n1 = node1 {
            stamper.stampRHS(n1, value)
        }
        if let n2 = node2 {
            stamper.stampRHS(n2, -value)
        }
    }
}
