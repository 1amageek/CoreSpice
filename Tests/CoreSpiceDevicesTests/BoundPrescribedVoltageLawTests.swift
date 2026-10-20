import CoreSpiceIR
@testable import CoreSpiceDevices
import Testing

@Suite("Actual bound prescribed voltage coordinate law", .timeLimit(.minutes(1)))
struct BoundPrescribedVoltageLawTests {
    private typealias E = CompensatedEnclosure
    private let p = Node(id: 1), n = Node(id: 2), b = Branch(id: 9)
    private enum Refusal: Error, Equatable { case work, cancelled, callback }
    private var axis: [MNAVariable: Int] { [.nodeVoltage(p): 2, .nodeVoltage(n): 0, .branchCurrent(b): 1] }

    private func bind(positive: Node? = nil, negative: Node? = nil,
        parameters: [String: ParameterValue] = ["v": .real(0)]) throws -> BoundVoltageSource {
        var context = BindingContext(variableMap: axis, matrixDimension: 3)
        let instance = Instance(name: "Vactual", typeName: "vsource", nodes: [positive ?? p, negative ?? n],
            parameters: parameters, ownedBranches: [b])
        return try #require(VoltageSourceDescriptor().bind(instance: instance, context: &context) as? BoundVoltageSource)
    }
    private func law(_ source: BoundVoltageSource, zero: Double = -0.375, one: Double = 1.625,
        origin: Double = 2, scale: Double = 0.5) throws -> BoundPrescribedVoltageLaw {
        try source.makePrescribedVoltageLaw(zeroVoltage: zero, oneVoltage: one,
            timeOrigin: origin, timeScale: scale, variableMap: axis, checkpoint: {})
    }
    private func bounds(_ value: E) -> (Double, Double) {
        let center = value.center.bounds
        return value.radius == 0 ? (center.lower, center.upper)
            : ((center.lower - value.radius).nextDown, (center.upper + value.radius).nextUp)
    }
    private func contains(_ value: E, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let (lo, hi) = bounds(value)
        #expect(lo <= expected && expected <= hi, sourceLocation: sourceLocation)
    }
    private func expectFailure(_ body: () throws -> Void,
        matching: (BoundPrescribedVoltageFailure) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        do { try body(); Issue.record("Invalid prescribed input succeeded", sourceLocation: sourceLocation) }
        catch let error as BoundPrescribedVoltageFailure { #expect(matching(error), sourceLocation: sourceLocation) }
    }

    @Test func exactDyadicPointAndIntervalValuesShareTheActualSourceEquation() throws {
        let source = try bind(), law = try self.law(source)
        // Independent integer/rational oracle: phi(j/8)=(-3+2*j)/8; time=(t-2)/(1/2).
        for j in 0...8 {
            let u = Double(j) / 8, expected = Double(-3 + 2 * j) / 8
            let point = try law.point(normalized: u, at: -2, checkpoint: {})
            #expect(point.voltage == expected)
            contains(point.voltageEnclosure, expected); contains(point.sourceTime, -8)
            let state = SolutionState(variables: [0.125, 0.5, 2], variableMap: axis)
            var values = [Double](repeating: 0, count: 3)
            try law.accumulateResidual(state: state, normalized: u, at: -2, checkpoint: {}) { values[$0] += $1 }
            #expect(values == [-0.5, 1.875 - expected, 0.5])
            var enclosed = [E?](repeating: nil, count: 3)
            try law.accumulateResidualEnclosure(state: state, normalized: u...u, at: -2, checkpoint: {}) {
                enclosed[$0] = try E(center: $1, radius: $2)
            }
            for row in values.indices { contains(try #require(enclosed[row]), values[row]) }
        }
        let jet = try law.enclose(normalized: 0.25...0.75, leftSlope: -2...3,
            rightSlope: -1...4, over: -2 ... -1, checkpoint: {})
        // Delta=2 and T=1/2: V in [1/8,9/8], left in [-8,12], right in [-4,16].
        for value in [0.125, 1.125] { contains(jet.voltage, value) }
        for value in [-8.0, 12] { contains(jet.leftSlope, value) }
        for value in [-4.0, 16] { contains(jet.rightSlope, value) }
        for value in [-8.0, -6] { contains(jet.sourceTime, value) }
        contains(law.externalPartial, -2)
        #expect(law.charge.center == .zero && law.charge.radius == 0)
    }

    @Test func groundedReversedFloatingAndCoincidentSourcesKeepSignedIncidences() throws {
        for (positive, negative) in [(p, Node.ground), (Node.ground, p), (p, n), (p, p)] {
            let source = try bind(positive: positive, negative: negative), law = try self.law(source, zero: 1, one: -3)
            let fact = law.sourceFact
            #expect(fact.positiveNode == positive && fact.negativeNode == negative && fact.branch == b)
            let state = SolutionState(variables: [0.25, 0.5, 2], variableMap: axis)
            var values = [Double](repeating: 0, count: 3)
            try law.accumulateResidual(state: state, normalized: 0.5, at: -10, checkpoint: {}) { values[$0] += $1 }
            var expected = [Double](repeating: 0, count: 3)
            if let row = fact.positiveRow { expected[row] += 0.5 }
            if let row = fact.negativeRow { expected[row] -= 0.5 }
            let vpos = positive == .ground ? 0 : (positive == p ? 2 : 0.25)
            let vneg = negative == .ground ? 0 : (negative == p ? 2 : 0.25)
            expected[1] = vpos - vneg + 1
            #expect(values == expected)
            contains(law.externalPartial, 4)
        }
    }

    @Test func pointProjectionRoundingIsSeparateFromTheExactAffineEquation() throws {
        let halfULP = 0x1p-53
        let source = try bind(negative: .ground)
        let law = try self.law(source, zero: 1, one: 1.0.nextUp, origin: 0, scale: 1)
        let point = try law.point(normalized: 0.5, at: 0, checkpoint: {})
        // Exact phi=1+2^-53 rounds to 1; the true branch F at Vpos=1 is -2^-53.
        #expect(point.voltage == 1 && point.roundingErrorBound >= halfULP)
        let state = SolutionState(variables: [0, 0, 1], variableMap: axis)
        var roundedBranch: Double?, exactBranch: E?
        try law.accumulateResidual(state: state, normalized: 0.5, at: 0, checkpoint: {}) {
            if $0 == 1 { roundedBranch = $1 }
        }
        try law.accumulateResidualEnclosure(state: state, normalized: 0.5...0.5, at: 0, checkpoint: {}) {
            if $0 == 1 { exactBranch = try E(center: $1, radius: $2) }
        }
        #expect(roundedBranch == 0)
        contains(try #require(exactBranch), -halfULP)
        #expect(try #require(exactBranch).center.high == -halfULP)
    }

    @Test func endpointDifferenceRetainsLowBitsSignedZeroAndSubnormalBounds() throws {
        let source = try bind()
        let large = 18_014_398_509_481_984.0 // 2^54; 1-large cannot be represented by one Double.
        let cancellation = try law(source, zero: large, one: 1, scale: 1)
        let point = try cancellation.point(normalized: 1, at: 2, checkpoint: {})
        #expect(point.voltage == 1)
        contains(point.voltageEnclosure, 1)
        contains(cancellation.externalPartial, large)
        let subnormal = Double.leastNonzeroMagnitude
        let tiny = try law(source, zero: 0, one: subnormal, scale: 1)
        let low = try tiny.enclose(normalized: 0...1, leftSlope: 0...1,
            rightSlope: -1...0, over: -1...1, checkpoint: {})
        for value in [0, subnormal] { contains(low.voltage, value); contains(low.leftSlope, value) }
        for value in [-subnormal, 0] { contains(low.rightSlope, value) }
        let zero = try law(source, zero: -0.0, one: 0, scale: 1)
        let z = try zero.point(normalized: 0.5, at: 0, checkpoint: {})
        #expect(z.voltage == 0 && z.voltageEnclosure.center == .zero)
    }

    @Test func missingCoordinateDomainTimeAndBindingRefuseBeforePublication() throws {
        let source = try bind(), law = try self.law(source)
        try expectFailure({ _ = try law.point(normalized: nil, at: 0, checkpoint: {}) }) {
            if case .missingCoordinate = $0 { return true }; return false
        }
        for u in [-0.1, 1.1, .nan, .infinity] {
            try expectFailure({ _ = try law.point(normalized: u, at: 0, checkpoint: {}) }) {
                if case .invalidDomain = $0 { return true }; return false
            }
        }
        try expectFailure({ _ = try law.point(normalized: 0.5, at: .nan, checkpoint: {}) }) {
            if case .invalidTime = $0 { return true }; return false
        }
        for scale in [0.0, -1, .infinity, .nan] {
            try expectFailure({ _ = try self.law(source, scale: scale) }) {
                if case .invalidTime = $0 { return true }; return false
            }
        }
        try expectFailure({ _ = try self.law(source, origin: .infinity) }) {
            if case .invalidTime = $0 { return true }; return false
        }
        try expectFailure({ _ = try self.law(source, zero: .nan) }) {
            if case .invalidEndpoint = $0 { return true }; return false
        }
        try expectFailure({ _ = try self.law(source, zero: -.greatestFiniteMagnitude, one: .greatestFiniteMagnitude) }) {
            if case .numerical = $0 { return true }; return false
        }
        try expectFailure({ _ = try law.enclose(normalized: -0.1...0.5, leftSlope: 0...0, rightSlope: 0...0, over: 0...1, checkpoint: {}) }) {
            if case .invalidDomain = $0 { return true }; return false
        }
        try expectFailure({ _ = try law.enclose(normalized: 0...1, leftSlope: 0 ... .infinity,
            rightSlope: 0...0, over: 0...1, checkpoint: {}) }) {
                if case .invalidDomain = $0 { return true }; return false
            }
        try expectFailure({ _ = try law.enclose(normalized: 0...1, leftSlope: 0...0,
            rightSlope: 0...0, over: 0 ... .infinity, checkpoint: {}) }) {
                if case .invalidTime = $0 { return true }; return false
            }
        let overflow = try self.law(source, scale: .leastNonzeroMagnitude)
        try expectFailure({ _ = try overflow.enclose(normalized: 0...1, leftSlope: 1...1,
            rightSlope: 1...1, over: 2...2, checkpoint: {}) }) {
                if case .numerical = $0 { return true }; return false
            }
        var wrong = axis; wrong[.nodeVoltage(p)] = 0; wrong[.nodeVoltage(n)] = 2
        try expectFailure({ _ = try source.makePrescribedVoltageLaw(zeroVoltage: 0, oneVoltage: 1,
            timeOrigin: 0, timeScale: 1, variableMap: wrong, checkpoint: {}) }) {
                if case .binding = $0 { return true }; return false
            }
        let state = SolutionState(variables: [0, 0, 0], variableMap: wrong)
        var published = 0
        try expectFailure({ try law.accumulateResidual(state: state, normalized: 0.5, at: 0, checkpoint: {}) { _, _ in published += 1 } }) {
            if case .binding = $0 { return true }; return false
        }
        #expect(published == 0)
        #expect(try law.point(normalized: 0.5, at: 0, checkpoint: {}).voltage == 0.625)
    }

    @Test func mandatoryWorkCancellationAndCallbackFailuresPreserveLawAndCounters() throws {
        let source = try bind()
        var count = 0
        let law = try source.makePrescribedVoltageLaw(zeroVoltage: 0, oneVoltage: 1,
            timeOrigin: 0, timeScale: 1, variableMap: axis, checkpoint: { count += 1 })
        let initial = count
        try expectFailure({ _ = try law.enclose(normalized: 0...1, leftSlope: 0...1, rightSlope: -1...0,
            over: -1...1, checkpoint: { count += 1; if count == initial + 3 { throw Refusal.work } }) }) {
                if case .control(let cause) = $0 { return cause as? Refusal == .work }; return false
            }
        #expect(count == initial + 3)
        try expectFailure({ _ = try law.point(normalized: 0.5, at: 0, checkpoint: { throw Refusal.cancelled }) }) {
            if case .control(let cause) = $0 { return cause as? Refusal == .cancelled }; return false
        }
        let state = SolutionState(variables: [0, 0.5, 1], variableMap: axis)
        try expectFailure({ try law.accumulateResidual(state: state, normalized: 0.5, at: 0, checkpoint: {}) { _, _ in throw Refusal.callback } }) {
            if case .callback(let cause) = $0 { return cause as? Refusal == .callback }; return false
        }
        #expect(try law.point(normalized: 0.5, at: 0, checkpoint: { count += 1 }).voltage == 0.5)
        #expect(count > initial + 3)
    }

    @Test func lawRetainsActualPreparedValueAndLeavesAllOrdinarySourceFamiliesUnchanged() throws {
        let families: [[String: ParameterValue]] = [
            ["v": .real(1)],
            ["v1": .real(1), "v2": .real(3), "td": .real(0.25), "tr": .real(0.5), "tf": .real(0.5), "pw": .real(0.5), "per": .real(2)],
            ["vo": .real(1), "va": .real(2), "freq": .real(1), "td": .real(0.25)],
            ["pwl": .realVector([0, 1, 0.5, 3, 1, 1])]
        ]
        for parameters in families {
            let source = try bind(parameters: parameters), fact = try source.independentVoltageSourceFact()
            let law = try self.law(source, zero: 4, one: 8, origin: -3, scale: 2)
            let state = SolutionState(variables: [1, 0.5, 1e16], variableMap: axis)
            var dc = [Double](repeating: 0, count: 3)
            try source.accumulatePhysicalResidual(state: state) { dc[$0] += $1 }
            #expect(dc[1].bitPattern == ((1e16 - 1) - fact.dcVoltage).bitPattern)
            for time in [-2.0, 0, 0.5, 3] {
                var residual = [Double](repeating: 0, count: 3), rhs = [Double](repeating: 0, count: 3)
                try source.accumulateTransientStaticResidual(state: state, time: time) { residual[$0] += $1 }
                let expected = (1e16 - 1) - fact.waveform.value(at: time)
                #expect(residual[1].bitPattern == expected.bitPattern)
                var stamper = MatrixStamper(variableMap: axis, stampMatrix: { _, _, _ in }, stampRHS: { rhs[$0] += $1 })
                source.stampTransient(into: &stamper, state: state,
                    integration: .init(method: .backwardEuler, timeStep: 0.125, currentTime: time))
                #expect(rhs[1].bitPattern == fact.waveform.value(at: time).bitPattern)
                var enclosed: (CompensatedValue, Double)?
                try source.accumulateTransientStaticResidualEnclosure(state: state, time: time) { row, center, radius in
                    if row == 1 { enclosed = (center, radius) }
                }
                let captured = try #require(enclosed)
                let scalar = try E(center: CompensatedValue(high: fact.waveform.value(at: time)))
                let reference = try E(center: CompensatedValue(high: 1e16))
                    .subtracting(E(center: CompensatedValue(high: 1))).subtracting(scalar)
                #expect(try E(center: captured.0, radius: captured.1) == reference)
            }
            // Explicit negative-time U belongs to the new law, not the original waveform's past clamp.
            #expect(try law.point(normalized: 0.75, at: -5, checkpoint: {}).voltage == 7)
            #expect(fact.waveform.value(at: -5) == 1)
        }
        let retained: BoundPrescribedVoltageLaw = try {
            let source = try bind(parameters: ["pwl": .realVector([0, 1, 1, 2])])
            return try law(source)
        }()
        #expect(try retained.point(normalized: 0.5, at: -100, checkpoint: {}).voltage == 0.625)
    }
}
