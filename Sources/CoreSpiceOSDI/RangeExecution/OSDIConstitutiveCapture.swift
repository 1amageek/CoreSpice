import OSDIContracts
import OSDIRuntime

/// One actual-bound conditional identity session; no global kernel or root authority.
package struct OSDIConstitutiveCapture: ~Copyable, Sendable {
    private let storage: OSDIConstitutiveCaptureStorage
    private let snapshot: OSDIConstitutiveSnapshot
    private let inventory: OSDIConstitutiveInventory
    private let evaluator: any OSDIPrecisionConstitutiveEvaluating

    init(session: consuming OSDIPrecisionSession, snapshot: OSDIConstitutiveSnapshot,
        inventory: OSDIConstitutiveInventory, evaluator: any OSDIPrecisionConstitutiveEvaluating,
        helperLease: any Sendable) {
        storage = OSDIConstitutiveCaptureStorage(session: consume session, helperLease: helperLease)
        self.snapshot = snapshot; self.inventory = inventory; self.evaluator = evaluator
    }

    package mutating func withCheckedIdentities<Result>(lowerHigh: borrowing Span<Double>, lowerLow: borrowing Span<Double>,
        upperHigh: borrowing Span<Double>, upperLow: borrowing Span<Double>,
        lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext, precisionBits: UInt32,
        _ body: (OSDIPrecisionConstitutiveEvaluationView, OSDIConstitutiveInventoryView) throws -> Result) throws -> Result {
        var current = try storage.checkout()
        let control = snapshot.control
        let expectedSource = current.chartBinding
        let rawRowCount = snapshot.program.topology.nodes.count
        let inventory = self.inventory
        let snapshot = self.snapshot
        do {
            try control.checkpoint(workUnits: 0)
            guard let coverLimits = current.decisionCoverLimits, let identityLimits = current.constitutiveLimits else {
                throw OSDIConstitutiveCaptureFailure.invalidBinding
            }
            let worker = current.workerReference, profile = current.numericProfile, options = current.options
            let outcome: Swift.Result<Result, any Error> = try evaluator.constructConstitutiveIdentities(session: &current,
                lowerHigh: lowerHigh, lowerLow: lowerLow, upperHigh: upperHigh, upperLow: upperLow,
                lowerContext: lowerContext, upperContext: upperContext, precisionBits: precisionBits) { view in
                do {
                    guard view.binding.source == expectedSource, view.binding.coordinateQuotient == inventory.quotient else {
                        throw OSDIConstitutiveCaptureFailure.invalidBinding
                    }
                    try control.checkpoint(workUnits: 0)
                    for claim in 0..<view.claimCount {
                        try control.checkpoint(workUnits: 1)
                        let rows = view.withClaim(at: claim) { $0.rawRowCount }
                        guard rows == rawRowCount else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
                    }
                    let retention = OSDIConstitutiveCaptureRetention(source: view.binding, workerReference: worker, numericProfile: profile,
                        options: options, coverLimits: coverLimits, identityLimits: identityLimits, snapshot: snapshot, inventory: inventory)
                    return .success(try inventory.withView(retention: retention) { try body(view, $0) })
                } catch { return .failure(error) }
            }
            let value = try outcome.get()
            try control.checkpoint(workUnits: 0)
            storage.restore(consume current)
            return value
        } catch {
            throw storage.fail(consume current, primary: error)
        }
    }

    package mutating func close() throws { try storage.close() }
}
