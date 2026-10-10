@testable import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

/// Test-only lower owner access for stamps, session sequencing and injected noise faults.
/// The record retains accounting reservations as long as the extracted devices remain live.
struct BoundBSIMFixture: Sendable {
    let record: NativeCircuitPreparationRecord
    let devices: [any BoundDevice]
    var plan: ExecutionPlan { record.plan }
    init(_ owner: consuming PreparedNativeCircuit) {
        (record, devices) = owner.takeState()
    }
}

extension Analysis {
    func run(circuit: BoundBSIMFixture, solver: any LinearSolver,
             observer: EventDispatcher?, cancellation: CancellationToken) async throws -> Result {
        try await run(plan: circuit.plan, devices: circuit.devices, solver: solver,
            observer: observer, cancellation: cancellation)
    }
}
