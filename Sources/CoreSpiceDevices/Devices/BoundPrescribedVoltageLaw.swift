import CoreSpiceIR

/// The actual ideal-source equation with an explicit exogenous coordinate.
/// Interval inputs remain caller assumptions; this value grants no history authority.
package struct BoundPrescribedVoltageLaw: Sendable {
    package struct Point: Sendable {
        package let sourceTime: CompensatedEnclosure
        package let voltage: Double
        package let voltageEnclosure: CompensatedEnclosure
        package let roundingErrorBound: Double
    }
    package struct Jet: Sendable {
        package let sourceTime: CompensatedEnclosure
        package let voltage: CompensatedEnclosure
        package let leftSlope: CompensatedEnclosure
        package let rightSlope: CompensatedEnclosure
    }
    package let sourceFact: IndependentVoltageSourceFact
    package let timeOrigin: Double
    package let timeScale: Double
    package let externalPartial: CompensatedEnclosure
    package let charge: CompensatedEnclosure
    private let source: BoundVoltageSource
    private let zeroVoltage: CompensatedEnclosure
    private let delta: CompensatedEnclosure
    private let scale: CompensatedEnclosure

    private init(source: BoundVoltageSource, fact: IndependentVoltageSourceFact, zero: CompensatedEnclosure,
        delta: CompensatedEnclosure, scale: CompensatedEnclosure, timeOrigin: Double, timeScale: Double) throws {
        self.source = source; sourceFact = fact; zeroVoltage = zero; self.delta = delta; self.scale = scale
        self.timeOrigin = timeOrigin; self.timeScale = timeScale
        externalPartial = try delta.negated()
        charge = try CompensatedEnclosure(center: .zero)
    }

    internal static func prepare(source: BoundVoltageSource, zeroVoltage: Double, oneVoltage: Double,
        timeOrigin: Double, timeScale: Double, variableMap: [MNAVariable: Int], checkpoint: () throws -> Void)
        throws(BoundPrescribedVoltageFailure) -> Self {
        do {
            try tick(checkpoint)
            guard zeroVoltage.isFinite, oneVoltage.isFinite else { throw BoundPrescribedVoltageFailure.invalidEndpoint }
            guard timeOrigin.isFinite, timeScale.isFinite, timeScale > 0 else { throw BoundPrescribedVoltageFailure.invalidTime }
            let fact = try source.independentVoltageSourceFact()
            guard variableMap[.nodeVoltage(.ground)] == nil,
                  fact.instance.typeName == "vsource", fact.instance.nodes.count == 2,
                  fact.instance.nodes[0] == fact.positiveNode, fact.instance.nodes[1] == fact.negativeNode,
                  fact.instance.ownedBranches.isEmpty || (fact.instance.ownedBranches.count == 1
                    && fact.instance.ownedBranches[0] == fact.branch) else {
                throw BoundPrescribedVoltageFailure.invalidBinding
            }
            try tick(checkpoint)
            try fact.validateJoin(variableMap: variableMap)
            try tick(checkpoint)
            let zero = try scalar(zeroVoltage), one = try scalar(oneVoltage)
            let difference = try one.subtracting(zero)
            try tick(checkpoint)
            let result = try Self(source: source, fact: fact, zero: zero, delta: difference,
                scale: scalar(timeScale), timeOrigin: timeOrigin, timeScale: timeScale)
            try tick(checkpoint)
            return result
        } catch { throw failure(error) }
    }

    /// No default phase or original-waveform fallback exists for an absent U.
    package func point(normalized value: Double?, at time: Double, checkpoint: () throws -> Void)
        throws(BoundPrescribedVoltageFailure) -> Point {
        do {
            try Self.tick(checkpoint)
            guard let value else { throw BoundPrescribedVoltageFailure.missingCoordinate }
            guard value.isFinite, (0...1).contains(value) else { throw BoundPrescribedVoltageFailure.invalidDomain }
            guard time.isFinite else { throw BoundPrescribedVoltageFailure.invalidTime }
            let sourceTime = try normalizedTime(time...time, checkpoint: checkpoint)
            try Self.tick(checkpoint)
            let voltage = try phi(Self.scalar(value))
            try Self.tick(checkpoint)
            let rounding = try voltage.subtracting(Self.scalar(voltage.center.high)).absoluteUpperBound
            guard rounding.isFinite else { throw NumericalStateError.arithmeticOverflow }
            try Self.tick(checkpoint)
            return Point(sourceTime: sourceTime, voltage: voltage.center.high,
                voltageEnclosure: voltage, roundingErrorBound: rounding)
        } catch { throw Self.failure(error) }
    }

    /// Bounds are explicit assumptions in normalized source time, not supplied proof authority.
    package func enclose(normalized: ClosedRange<Double>, leftSlope: ClosedRange<Double>,
        rightSlope: ClosedRange<Double>, over time: ClosedRange<Double>, checkpoint: () throws -> Void)
        throws(BoundPrescribedVoltageFailure) -> Jet {
        do {
            try Self.tick(checkpoint)
            guard normalized.lowerBound.isFinite, normalized.upperBound.isFinite,
                  normalized.lowerBound >= 0, normalized.upperBound <= 1 else {
                throw BoundPrescribedVoltageFailure.invalidDomain
            }
            let sourceTime = try normalizedTime(time, checkpoint: checkpoint)
            try Self.tick(checkpoint)
            let voltage = try phi(Self.interval(normalized))
            try Self.tick(checkpoint)
            let left = try delta.multiplied(by: Self.interval(leftSlope)).divided(by: scale)
            try Self.tick(checkpoint)
            let right = try delta.multiplied(by: Self.interval(rightSlope)).divided(by: scale)
            try Self.tick(checkpoint)
            return Jet(sourceTime: sourceTime, voltage: voltage, leftSlope: left, rightSlope: right)
        } catch { throw Self.failure(error) }
    }

    package func accumulateResidual(state: SolutionState, normalized: Double?, at time: Double,
        checkpoint: () throws -> Void, add: (Int, Double) throws -> Void) throws(BoundPrescribedVoltageFailure) {
        do {
            let evaluated = try point(normalized: normalized, at: time, checkpoint: checkpoint)
            try source.accumulatePrescribedResidual(state: state, voltage: evaluated.voltage,
                checkpoint: { try Self.tick(checkpoint) }) { row, value in
                    do { try add(row, value) } catch { throw BoundPrescribedVoltageFailure.callback(error) }
                }
            try Self.tick(checkpoint)
        } catch { throw Self.failure(error) }
    }

    /// Uses the same physical phi for the paired state; only U is interval-valued here.
    package func accumulateResidualEnclosure(state: SolutionState, normalized: ClosedRange<Double>,
        at time: Double, checkpoint: () throws -> Void,
        add: (Int, CompensatedValue, Double) throws -> Void) throws(BoundPrescribedVoltageFailure) {
        do {
            try Self.tick(checkpoint)
            guard normalized.lowerBound.isFinite, normalized.upperBound.isFinite,
                  normalized.lowerBound >= 0, normalized.upperBound <= 1 else {
                throw BoundPrescribedVoltageFailure.invalidDomain
            }
            guard time.isFinite else { throw BoundPrescribedVoltageFailure.invalidTime }
            _ = try normalizedTime(time...time, checkpoint: checkpoint)
            try Self.tick(checkpoint)
            let voltage = try phi(Self.interval(normalized))
            try source.accumulatePrescribedResidualEnclosure(state: state, voltage: voltage,
                checkpoint: { try Self.tick(checkpoint) }) { row, center, radius in
                    do { try add(row, center, radius) } catch { throw BoundPrescribedVoltageFailure.callback(error) }
                }
            try Self.tick(checkpoint)
        } catch { throw Self.failure(error) }
    }

    package func normalizedTime(_ time: ClosedRange<Double>, checkpoint: () throws -> Void)
        throws(BoundPrescribedVoltageFailure) -> CompensatedEnclosure {
        do {
            try Self.tick(checkpoint)
            guard time.lowerBound.isFinite, time.upperBound.isFinite else { throw BoundPrescribedVoltageFailure.invalidTime }
            let result = try Self.interval(time).subtracting(Self.scalar(timeOrigin)).divided(by: scale)
            try Self.tick(checkpoint)
            return result
        } catch { throw Self.failure(error) }
    }

    private func phi(_ value: CompensatedEnclosure) throws -> CompensatedEnclosure {
        try zeroVoltage.adding(delta.multiplied(by: value))
    }
    private static func scalar(_ value: Double) throws -> CompensatedEnclosure {
        try CompensatedEnclosure(center: CompensatedValue(high: value))
    }
    private static func interval(_ range: ClosedRange<Double>) throws -> CompensatedEnclosure {
        guard range.lowerBound.isFinite, range.upperBound.isFinite else { throw BoundPrescribedVoltageFailure.invalidDomain }
        if range.lowerBound == range.upperBound { return try scalar(range.lowerBound) }
        let low = try scalar(range.lowerBound), high = try scalar(range.upperBound), two = try scalar(2)
        let middle = try low.divided(by: two).adding(high.divided(by: two))
        let radius = max(try low.subtracting(middle).absoluteUpperBound, try high.subtracting(middle).absoluteUpperBound)
        guard radius.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return try CompensatedEnclosure(center: middle.center, radius: radius)
    }
    private static func tick(_ checkpoint: () throws -> Void) throws {
        do { try checkpoint() } catch { throw BoundPrescribedVoltageFailure.control(error) }
    }
    private static func failure(_ error: any Error) -> BoundPrescribedVoltageFailure {
        if let error = error as? BoundPrescribedVoltageFailure { return error }
        if let error = error as? NumericalStateError { return .numerical(error) }
        return .binding(error)
    }
}
