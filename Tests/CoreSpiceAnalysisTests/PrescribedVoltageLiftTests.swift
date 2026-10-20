import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import Synchronization
import Testing
@testable import CoreSpiceAnalysis

@Suite("Value-only prescribed voltage affine lift", .timeLimit(.minutes(1)))
struct PrescribedVoltageLiftTests {
    private typealias R = PrescribedVoltageReduction
    private typealias E = CompensatedEnclosure
    private final class Control: LinearSolverExecutionControlling {
        enum Refusal: Error { case work, storage, cancelled }
        private struct State { var live = 0; var work = 0; var cancelled = false; var refuse = false; var remaining: Int? = nil }
        private let state = Mutex(State())
        var live: Int { state.withLock { $0.live } }
        var work: Int { state.withLock { $0.work } }
        func arm(cancelled: Bool = false, storage: Bool = false, work: Int? = nil) {
            state.withLock { $0.cancelled = cancelled; $0.refuse = storage; $0.remaining = work }
        }
        func checkpoint(workUnits: Int) throws {
            try state.withLock { value in
                if value.cancelled { throw Refusal.cancelled }
                if let remaining = value.remaining {
                    guard workUnits <= remaining else { throw Refusal.work }; value.remaining = remaining - workUnits
                }
                value.work += workUnits
            }
        }
        func reserveStorage(byteCount: Int) throws -> any Sendable {
            try checkpoint(workUnits: 0)
            try state.withLock { value in
                guard !value.refuse else { throw Refusal.storage }; value.live += byteCount
            }
            return Lease(control: self, count: byteCount)
        }
        private final class Lease: Sendable {
            let control: Control, count: Int
            init(control: Control, count: Int) { self.control = control; self.count = count }
            deinit { control.state.withLock { $0.live -= count } }
        }
    }
    private func reduction(_ control: Control) throws -> R {
        try .init(limits: .init(maximumAxes: 16, maximumSources: 8,
            maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576), control: control)
    }
    private func e(_ value: Double, radius: Double = 0) throws -> E { try .init(center: .init(high: value), radius: radius) }

    @Test func affineLiftAndOldApplyShareIdenticalNoncurrentArithmetic() throws {
        let control = Control(), reduction = try reduction(control)
        do {
            let plan = try reduction.prepare(axes: [.electricalPotential, .electricalPotential, .electricalFlow, .thermalPotential, .electricalFlow],
                sources: [.init(positiveRow: 1, negativeRow: 0, branchRow: 2)])
            let workspace = try reduction.makeWorkspace(plan: plan)
            let z = try [e(0.25, radius: 0.01), e(4, radius: 0.2), e(7)]
            let u = try [e(1, radius: 0.03)], zero = try e(0)
            let lift = try reduction.lift(workspace: workspace, reducedCoordinates: z, sourceValues: u)
            let applied = try reduction.apply(workspace: workspace, reducedCoordinates: z, sourceValues: u,
                staticResidual: [zero, zero, zero, zero, zero], stateChargeRate: [zero, zero, zero, zero, zero],
                prescribedChargeRate: [zero, zero, zero, zero, zero], explicitTimeChargeRate: [zero, zero, zero, zero, zero])
            for row in [0, 1, 3, 4] { #expect(try lift.coordinate(at: row) == applied.coordinate(at: row)) }
            #expect(throws: R.Failure.invalidInput) { try lift.coordinate(at: 2) }
            #expect(try lift.coordinate(at: 3) == z[1])
            #expect(try lift.coordinate(at: 4) == z[2])
        }
        #expect(control.live == 0)
    }

    @Test func groundedReversedLiftHasNoInventedCurrentOrRate() throws {
        let control = Control(), reduction = try reduction(control)
        let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow],
            sources: [.init(positiveRow: nil, negativeRow: 0, branchRow: 1)])
        let workspace = try reduction.makeWorkspace(plan: plan)
        let lift = try reduction.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)])
        #expect(try lift.coordinate(at: 0) == e(-1))
        #expect(throws: R.Failure.invalidInput) { try lift.coordinate(at: 1) }
        #expect(throws: R.Failure.invalidInput) { try lift.coordinate(at: -1) }
        #expect(throws: R.Failure.invalidInput) { try lift.coordinate(at: 2) }
    }

    @Test func wrongOwnerAndShapeRefusalsDoNotConsumeWorkspace() throws {
        let control = Control(), first = try reduction(control), other = try reduction(control)
        let plan = try first.prepare(axes: [.electricalPotential, .electricalFlow],
            sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
        let workspace = try first.makeWorkspace(plan: plan), baseline = control.live
        #expect(throws: R.Failure.wrongOwner) { try other.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)]) }
        #expect(throws: R.Failure.invalidInput) { try first.lift(workspace: workspace, reducedCoordinates: [e(1)], sourceValues: [e(1)]) }
        #expect(throws: R.Failure.invalidInput) { try first.lift(workspace: workspace, reducedCoordinates: [], sourceValues: []) }
        #expect(control.live == baseline)
        #expect(try first.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)]).coordinate(at: 0) == e(1))
    }

    @Test func cumulativeControlFailuresAndFinalResultCopyRefund() throws {
        let control = Control(), reduction = try reduction(control)
        do {
            let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow],
                sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
            let workspace = try reduction.makeWorkspace(plan: plan), baseline = control.live
            control.arm(cancelled: true)
            #expect(throws: Control.Refusal.cancelled) { try reduction.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)]) }
            control.arm(storage: true)
            #expect(throws: Control.Refusal.storage) { try reduction.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)]) }
            control.arm(work: 0)
            #expect(throws: Control.Refusal.work) { try reduction.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)]) }
            control.arm()
            #expect(control.live == baseline)
            let before = control.work
            var held: R.Lift?
            do { held = try reduction.lift(workspace: workspace, reducedCoordinates: [], sourceValues: [e(1)]) }
            withExtendedLifetime(held) { #expect(control.live > baseline) }
            held = nil
            #expect(control.live == baseline && control.work > before)
        }
        #expect(control.live == 0)
    }
}
