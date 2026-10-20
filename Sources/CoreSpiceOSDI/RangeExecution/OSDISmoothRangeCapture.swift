import OSDIContracts
import OSDIRuntime

/// Only concrete SDK smooth-box evaluation on a checked actual-bound exclusive session.
package struct OSDISmoothRangeCapture: ~Copyable, Sendable {
    private let storage: OSDISmoothRangeStorage
    private let snapshot: OSDIConstitutiveSnapshot
    private let inventory: OSDIConstitutiveInventory
    init(session: consuming OSDIPrecisionSession, snapshot: OSDIConstitutiveSnapshot,
        inventory: OSDIConstitutiveInventory, lease: any Sendable) {
        storage = OSDISmoothRangeStorage(session: consume session, lease: lease)
        self.snapshot = snapshot; self.inventory = inventory
    }
    package mutating func withCheckedRange<Result>(lowerHigh: borrowing Span<Double>, lowerLow: borrowing Span<Double>,
        upperHigh: borrowing Span<Double>, upperLow: borrowing Span<Double>,
        lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext, precisionBits: UInt32,
        _ body: (OSDIPrecisionRangeEvaluationView, OSDIConstitutiveInventoryView, OSDISmoothRangeScope) throws -> Result) throws -> Result {
        var current = try storage.checkout()
        let snapshot = self.snapshot, inventory = self.inventory, control = snapshot.control
        do {
            try control.checkpoint(workUnits: 0)
            guard current.chartBinding == OSDIPrecisionChartBinding(program: snapshot.program),
                  current.options == snapshot.options else { throw OSDISmoothRangeFailure.invalidBinding }
            let raw = snapshot.program.topology.nodes.count
            let square = try OSDIConstitutiveCapacity.multiply(raw, raw)
            let source = current.chartBinding, worker = current.workerReference
            let profile = current.numericProfile, options = current.options
            // No source or pointer is inferred from v2 spans. This concrete call owns
            // the checked session and immutable source/query throughout the borrow.
            let outcome: Swift.Result<Result, any Error> = try OSDINativePrecisionEvaluator().evaluateRange(session: &current,
                lowerHigh: lowerHigh, lowerLow: lowerLow, upperHigh: upperHigh, upperLow: upperLow,
                lowerContext: lowerContext, upperContext: upperContext, precisionBits: precisionBits) { view in
                    do {
                        try control.checkpoint(workUnits: 0)
                        guard !view.programHasTimeInput else { throw OSDISmoothRangeFailure.explicitTimeInput }
                        guard view.fLower.count == raw, view.fUpper.count == raw,
                              view.qLower.count == raw, view.qUpper.count == raw,
                              view.gLower.count == square, view.gUpper.count == square,
                              view.cLower.count == square, view.cUpper.count == square else { throw OSDISmoothRangeFailure.invalidBinding }
                        try control.checkpoint(workUnits: OSDIConstitutiveCapacity.multiply(4,
                            OSDIConstitutiveCapacity.add(raw, square)))
                        func validate(_ lo: borrowing Span<Double>, _ hi: borrowing Span<Double>) throws {
                            for i in 0..<lo.count {
                                try control.checkpoint(workUnits: 1)
                                guard lo[i].isFinite, hi[i].isFinite, lo[i] <= hi[i] else { throw OSDISmoothRangeFailure.invalidBinding }
                            }
                        }
                        try validate(view.fLower, view.fUpper); try validate(view.qLower, view.qUpper)
                        try validate(view.gLower, view.gUpper); try validate(view.cLower, view.cUpper)
                        let scope = try OSDISmoothRangeScope(source: source, workerReference: worker,
                            numericProfile: profile, options: options, snapshot: snapshot, inventory: inventory,
                            lowerHigh: lowerHigh, lowerLow: lowerLow, upperHigh: upperHigh, upperLow: upperLow,
                            lowerContext: lowerContext, upperContext: upperContext, usedPrecisionBits: view.usedPrecisionBits)
                        return .success(try inventory.withView { try body(view, $0, scope) })
                    } catch { return .failure(error) }
                }
            let result = try outcome.get()
            try control.checkpoint(workUnits: 0)
            storage.restore(consume current)
            return result
        } catch { throw storage.fail(consume current, primary: error) }
    }
    package mutating func close() throws { try storage.close() }
}
