/// Precharged batches bound callback overhead and cancellation latency.
struct SparseLUWorkMeter {
    let control: (any LinearSolverExecutionControlling)?
    private(set) var work = 0
    private(set) var charged = 0
    private var credit = 0
    private var callsUntilPoll = 256

    mutating func spend(_ count: Int = 1) throws {
        let (next, overflow) = work.addingReportingOverflow(count)
        guard count >= 0, !overflow else { throw SparseSolverError.workOverflow }
        if count > credit, let control {
            let batch = max(count, 256)
            let (nextCharged, chargeOverflow) = charged.addingReportingOverflow(batch)
            guard !chargeOverflow else { throw SparseSolverError.workOverflow }
            try control.checkpoint(workUnits: batch)
            credit = batch
            charged = nextCharged
        }
        // Keep the strong owner in the meter; bind it only at an actual checkpoint.
        if control != nil {
            credit -= count
            callsUntilPoll -= 1
            if callsUntilPoll == 0 {
                try control?.checkpoint(workUnits: 0)
                callsUntilPoll = 256
            }
        }
        work = next
    }
}
