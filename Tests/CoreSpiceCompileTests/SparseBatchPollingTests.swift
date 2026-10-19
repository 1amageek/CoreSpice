import Synchronization
import Testing
@testable import CoreSpiceCompile

@Suite("Sparse bounded work polling", .timeLimit(.minutes(1)))
struct SparseBatchPollingTests {
    @Test func unitWorkPreservesAdmissionAndPollingBoundaries() throws {
        let recorder = Recorder()
        var meter = SparseLUWorkMeter(control: Control(recorder: recorder))
        for _ in 0..<255 { try meter.spend() }
        #expect(recorder.snapshot.callbacks == [256])
        #expect(meter.work == 255 && meter.charged == 256)

        try meter.spend()
        #expect(recorder.snapshot.callbacks == [256, 0])
        #expect(meter.work == 256 && meter.charged == 256)
        try meter.spend()
        #expect(recorder.snapshot.callbacks == [256, 0, 256])
        #expect(meter.work == 257 && meter.charged == 512)

        for _ in 0..<255 { try meter.spend() }
        #expect(recorder.snapshot.callbacks == [256, 0, 256, 0])
        #expect(meter.work == 512 && meter.charged == 512)
        try meter.spend()
        #expect(recorder.snapshot.callbacks == [256, 0, 256, 0, 256])
        #expect(meter.work == 513 && meter.charged == 768)
    }

    @Test func zeroWorkStillPollsWithoutCharging() throws {
        let recorder = Recorder()
        var meter = SparseLUWorkMeter(control: Control(recorder: recorder))
        for _ in 0..<255 { try meter.spend(0) }
        #expect(recorder.snapshot.callbacks.isEmpty)
        try meter.spend(0)
        #expect(recorder.snapshot.callbacks == [0])
        #expect(meter.work == 0 && meter.charged == 0)
        try meter.spend()
        #expect(recorder.snapshot.callbacks == [0, 256])
        #expect(meter.work == 1 && meter.charged == 256)
    }

    @Test func allocationCreditCannotDelayTraversalCancellation() throws {
        let recorder = Recorder()
        recorder.setFailure(.cancelled)
        var meter = SparseLUWorkMeter(control: Control(recorder: recorder))
        try meter.spend(1_000_000)
        for _ in 0..<254 { try meter.spend() }
        #expect(recorder.snapshot.callbacks == [1_000_000, 256])
        #expect(meter.work == 1_000_254 && meter.charged == 1_000_256)
        #expect(throws: Stop.cancelled) { try meter.spend() }
        #expect(recorder.snapshot.callbacks == [1_000_000, 256, 0])
        #expect(meter.work == 1_000_254 && meter.charged == 1_000_256)
    }

    @Test func refusedAdmissionPrecedesWorkAndPreservesTheCause() throws {
        let recorder = Recorder()
        recorder.setFailure(.refused)
        var meter = SparseLUWorkMeter(control: Control(recorder: recorder))
        #expect(throws: Stop.refused) { try meter.spend() }
        #expect(recorder.snapshot.callbacks == [256])
        #expect(meter.work == 0 && meter.charged == 0)
        recorder.setFailure(nil)
        try meter.spend()
        #expect(recorder.snapshot.callbacks == [256, 256])
        #expect(meter.work == 1 && meter.charged == 256)
    }

    @Test func unboundedWorkAndInvalidCountsRetainTheirContract() throws {
        var meter = SparseLUWorkMeter(control: nil)
        try meter.spend(0)
        try meter.spend(257)
        #expect(meter.work == 257 && meter.charged == 0)
        #expect(throws: SparseSolverError.workOverflow) { try meter.spend(-1) }
        #expect(meter.work == 257 && meter.charged == 0)
        try meter.spend(Int.max - 257)
        #expect(meter.work == Int.max && meter.charged == 0)
        #expect(throws: SparseSolverError.workOverflow) { try meter.spend() }
        #expect(meter.work == Int.max && meter.charged == 0)
    }

    @Test func roundedAdmissionOverflowIsRejectedBeforeTheCallback() throws {
        let recorder = Recorder()
        var meter = SparseLUWorkMeter(control: Control(recorder: recorder))
        try meter.spend()
        #expect(throws: SparseSolverError.workOverflow) { try meter.spend(Int.max - 1) }
        #expect(recorder.snapshot.callbacks == [256])
        #expect(meter.work == 1 && meter.charged == 256)
    }

    @Test func copiesRetainTheControllerUntilTheFinalOwnerIsReleased() throws {
        let recorder = Recorder()
        var original: SparseLUWorkMeter?
        var copy: SparseLUWorkMeter?
        do {
            let control = Control(recorder: recorder)
            original = SparseLUWorkMeter(control: control)
            copy = original
        }
        #expect(recorder.snapshot.controllerDeinitializations == 0)
        try original?.spend()
        original = nil
        #expect(recorder.snapshot.controllerDeinitializations == 0)
        try copy?.spend()
        #expect(recorder.snapshot.callbacks == [256, 256])
        copy = nil
        #expect(recorder.snapshot.controllerDeinitializations == 1)
    }

    private enum Stop: Error, Sendable, Equatable { case cancelled, refused }

    private final class Recorder: Sendable {
        struct State: Sendable {
            var callbacks: [Int] = []
            var failure: Stop?
            var controllerDeinitializations = 0
        }
        private let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }

        func setFailure(_ failure: Stop?) { state.withLock { $0.failure = failure } }

        func checkpoint(workUnits: Int) throws {
            try state.withLock {
                $0.callbacks.append(workUnits)
                if workUnits == 0, $0.failure == .cancelled { throw Stop.cancelled }
                if workUnits > 0, $0.failure == .refused { throw Stop.refused }
            }
        }

        func controllerReleased() { state.withLock { $0.controllerDeinitializations += 1 } }
    }

    private final class Control: LinearSolverExecutionControlling {
        let recorder: Recorder
        init(recorder: Recorder) { self.recorder = recorder }
        func checkpoint(workUnits: Int) throws { try recorder.checkpoint(workUnits: workUnits) }
        func reserveStorage(byteCount: Int) throws -> any Sendable { byteCount }
        deinit { recorder.controllerReleased() }
    }
}
