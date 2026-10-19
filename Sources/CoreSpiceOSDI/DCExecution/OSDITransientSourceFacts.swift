import CoreSpiceDevices
import OSDIContracts

/// Fixed owned source outputs; a complete exact key makes the record consumable once.
struct OSDITransientSourceFacts: ~Copyable, Sendable {
    struct Key: Sendable {
        let integration: IntegrationState
        let generation: UInt64
        var ordinaryContext: OSDIEvaluationContext? = nil
        var ordinaryReference: OSDIEvaluationContext? = nil
        var precisionContext: OSDIPrecisionContext? = nil
        var precisionReference: OSDIPrecisionContext? = nil

        func matches(_ other: Self) -> Bool {
            generation == other.generation && Self.same(ordinaryContext, other.ordinaryContext)
                && Self.same(ordinaryReference, other.ordinaryReference) && Self.same(precisionContext, other.precisionContext)
                && Self.same(precisionReference, other.precisionReference) && integration.method == other.integration.method
                && integration.currentTime.bitPattern == other.integration.currentTime.bitPattern
                && integration.timeStep.bitPattern == other.integration.timeStep.bitPattern
                && integration.timeStepLowComponent.bitPattern == other.integration.timeStepLowComponent.bitPattern
                && integration.previousTimeStep?.bitPattern == other.integration.previousTimeStep?.bitPattern
                && integration.previousTimeStepLowComponent?.bitPattern == other.integration.previousTimeStepLowComponent?.bitPattern
        }
        private static func same(_ left: OSDIEvaluationContext?, _ right: OSDIEvaluationContext?) -> Bool {
            left?.mode == right?.mode && left?.timeSeconds.bitPattern == right?.timeSeconds.bitPattern
                && left?.noiseFrequencyHz?.bitPattern == right?.noiseFrequencyHz?.bitPattern
        }
        private static func same(_ left: OSDIPrecisionContext?, _ right: OSDIPrecisionContext?) -> Bool {
            left?.mode == right?.mode && left?.timeHigh.bitPattern == right?.timeHigh.bitPattern
                && left?.timeLow.bitPattern == right?.timeLow.bitPattern
        }
    }
    var key: Key?
    var candidateHigh: [Double]
    var candidateLow: [Double]
    var fHigh: [Double]
    var fLow: [Double]
    var fRadius: [Double]
    // Ordinary Q or the explicit precision model's delta-Q, never a rounded Q subtraction.
    var qHigh: [Double]
    var qLow: [Double]
    var qRadius: [Double]
    var evaluationCount: UInt64 = 0

    init(active: Int, raw: Int, precision: Bool) {
        candidateHigh = Array(repeating: 0, count: active)
        candidateLow = Array(repeating: 0, count: precision ? active : 0)
        fHigh = Array(repeating: 0, count: raw); qHigh = Array(repeating: 0, count: raw)
        fLow = Array(repeating: 0, count: precision ? raw : 0)
        fRadius = Array(repeating: 0, count: precision ? raw : 0)
        qLow = Array(repeating: 0, count: precision ? raw : 0)
        qRadius = Array(repeating: 0, count: precision ? raw : 0)
    }
    mutating func invalidate() { key = nil }
    mutating func willEvaluate() throws(OSDIAdapterFailure) {
        invalidate()
        let (next, overflow) = evaluationCount.addingReportingOverflow(1)
        guard !overflow else { throw .capacityExceeded }
        evaluationCount = next
    }
    mutating func publish(key: Key, high: borrowing Span<Double>, low: borrowing Span<Double>) {
        for index in candidateHigh.indices { candidateHigh[index] = high[index] }
        for index in candidateLow.indices { candidateLow[index] = low[index] }
        self.key = key
    }
    borrowing func matches(key: Key, high: borrowing Span<Double>, low: borrowing Span<Double>) -> Bool {
        guard let stored = self.key, stored.matches(key), high.count == candidateHigh.count,
              low.count == candidateLow.count else { return false }
        for index in candidateHigh.indices where high[index].bitPattern != candidateHigh[index].bitPattern { return false }
        for index in candidateLow.indices where low[index].bitPattern != candidateLow[index].bitPattern { return false }
        return true
    }
}
