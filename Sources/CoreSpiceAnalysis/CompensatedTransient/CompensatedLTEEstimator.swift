import CoreSpiceDevices

/// The existing state indicators evaluated with retained lows and outward arithmetic.
internal struct CompensatedLTEEstimator {
    func estimate(
        current: SolutionState, threePrevious: [Double], threePreviousLow: [Double],
        half: [Double], halfLow: [Double], quarter: [Double], quarterLow: [Double],
        integration: IntegrationState, twoPreviousTimeStep: Double?, twoPreviousTimeStepLow: Double?,
        bootstrap: Bool, embedded: Bool, excluded: Set<Int>, relativeTolerance: Double,
        absoluteTolerances: [Double]?, defaultAbsoluteTolerance: Double
    ) throws -> Double {
        let count = current.variables.count
        try current.validateCompensatedComponents()
        let h = try enclosed(integration.compensatedTimeStep)
        let two = try scalar(2), three = try scalar(3), four = try scalar(4)
        var maximum = 0.0
        for i in 0..<count where !excluded.contains(i) {
            let value = try current.checkedCompensatedValue(at: i)
            let x = try enclosed(value)
            let error: CompensatedEnclosure
            if embedded {
                error = try x.subtracting(at(quarter, quarterLow, i))
            } else if bootstrap {
                error = try x.subtracting(at(half, halfLow, i).multiplied(by: three))
                    .adding(at(quarter, quarterLow, i).multiplied(by: two)).multiplied(by: four).divided(by: three)
            } else {
                guard let previous = current.previousVariables, let older = current.twoPreviousVariables,
                      let previousH = try integration.compensatedPreviousTimeStep else {
                    throw LTEEstimator.EstimationError.insufficientHistory
                }
                let previousLow = current.previousVariableLowComponents
                let olderLow = current.twoPreviousVariableLowComponents
                let p = try at(previous, previousLow, i), o = try at(older, olderLow, i)
                let ph = try enclosed(previousH)
                let recent = try x.subtracting(p).divided(by: h)
                let middle = try p.subtracting(o).divided(by: ph)
                if integration.method == .backwardEuler {
                    error = try recent.subtracting(middle).divided(by: h.adding(ph))
                        .multiplied(by: h).multiplied(by: h)
                } else {
                    guard let olderH = twoPreviousTimeStep else { throw LTEEstimator.EstimationError.insufficientHistory }
                    let oh = try enclosed(CompensatedValue(high: olderH, low: twoPreviousTimeStepLow ?? 0))
                    let oldest = try at(threePrevious, threePreviousLow, i)
                    let oldestSlope = try o.subtracting(oldest).divided(by: oh)
                    let a = try recent.subtracting(middle).divided(by: h.adding(ph))
                    let b = try middle.subtracting(oldestSlope).divided(by: ph.adding(oh))
                    error = try a.subtracting(b).divided(by: h.adding(ph).adding(oh))
                        .multiplied(by: h).multiplied(by: h).multiplied(by: h).divided(by: two)
                }
            }
            let bounds = value.bounds
            let minimumMagnitude = bounds.lower <= 0 && bounds.upper >= 0 ? 0 : min(abs(bounds.lower), abs(bounds.upper))
            let absolute = absoluteTolerances?[i] ?? defaultAbsoluteTolerance
            let denominator = ((relativeTolerance * minimumMagnitude).nextDown + absolute).nextDown
            guard denominator.isFinite, denominator > 0 else { throw LTEEstimator.EstimationError.invalidTolerance }
            let indicator = (error.absoluteUpperBound / denominator).nextUp
            guard indicator.isFinite else { throw TransientExecutionError.nonFiniteLTE(indicator) }
            maximum = max(maximum, indicator)
        }
        return maximum
    }

    private func enclosed(_ value: CompensatedValue) throws -> CompensatedEnclosure { try .init(center: value) }
    private func scalar(_ value: Double) throws -> CompensatedEnclosure { try enclosed(CompensatedValue(high: value)) }
    private func at(_ high: [Double], _ low: [Double]?, _ index: Int) throws -> CompensatedEnclosure {
        guard high.indices.contains(index) else { throw LTEEstimator.EstimationError.invalidVectorDimensions }
        if let low, low.count != high.count { throw LTEEstimator.EstimationError.invalidVectorDimensions }
        return try enclosed(CompensatedValue(high: high[index], low: low?[index] ?? 0))
    }
}
