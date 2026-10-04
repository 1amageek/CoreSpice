import Foundation
import Testing
@testable import CoreSpiceCompactModels

@Suite("BSIM4 original kernel", .timeLimit(.minutes(1)))
struct BSIM4KernelTests {
    private func make(_ polarity: BSIM4Configuration.Polarity = .nmos,
                      model: [String: Double] = [:], instance: [String: Double] = [:]) throws -> BSIM4Evaluator {
        try BSIM4Evaluator(configuration: BSIM4Configuration(polarity: polarity, noiseRequested: true, maximumStressIterations: 8,
            modelParameters: ["toxe": 1e-8, "vth0": polarity == .nmos ? 0.7 : -0.7, "u0": 0.05].merging(model) { _, new in new },
            instanceParameters: ["l": 1e-6, "w": 1e-5].merging(instance) { _, new in new }))
    }
    private func bias(_ evaluator: BSIM4Evaluator) -> SIMD16<Double> {
        let t = evaluator.topology
        var v = SIMD16<Double>(repeating: 0)
        v[1] = 1; v[2] = 1.2; v[t.drainPrime] = 1; v[t.gatePrime] = 1.2; v[t.gateMid] = 1.2
        return v
    }
    @Test func coldAdmissionAndExactVersion() throws {
        #expect(throws: BSIM4Error.unsupportedVersion("4.8.1")) {
            try BSIM4Evaluator(configuration: .init(polarity: .nmos, version: "4.8.1", noiseRequested: true, maximumStressIterations: 8))
        }
        #expect(throws: BSIM4Error.invalidParameter(name: "mobmod", model: true)) { try make(model: ["mobmod": 7]) }
        #expect(throws: BSIM4Error.invalidParameter(name: "m", model: false)) { try make(instance: ["m": 3]) }
        #expect(throws: BSIM4Error.invalidParameter(name: "nf", model: false)) { try make(instance: ["nf": 1e30]) }
        #expect(throws: BSIM4Error.self) { try make(model: ["toxe": 0]) }
        #expect(throws: BSIM4Error.self) { try make(model: ["phin": -2]) }
        #expect(throws: BSIM4Error.self) { try make(model: ["u0": 0.05, "U0": 0.06]) }
        #expect(throws: BSIM4Error.resourceBudgetExceeded) {
            try make(instance: ["nf": 9, "sa": 1e-6, "sb": 1e-6, "sd": 1e-6])
        }
        let stress = try make(instance: ["nf": 1.5, "sa": 1e-6, "sb": 1e-6, "sd": 1e-6])
        #expect(try stress.evaluate(bias: bias(stress), analysis: .dc).operatingPoint[0] > 0)
        let e = try make()
        #expect(e.topology.nodeCount == 4)
        #expect(try e.evaluate(bias: bias(e), analysis: .dc).operatingPoint[0] > 0)
    }
    @Test func originalModeOneWarningAndQualification() throws {
        for checking in [0.0, 1.0] {
            let e = try make(model: ["tnoimod": 1, "paramchk": checking])
            #expect(e.topology.maintainerUnsupportedNoiseMode)
            #expect(e.topology.noiseRequested)
            #expect(e.topology.drainPrime != 1 && e.topology.sourcePrime != 3)
            #expect(e.diagnostics.contains { $0.code == .maintainerNoiseModeLimitation } == (checking == 1))
            #expect(try e.evaluate(bias: bias(e), analysis: .dc).operatingPoint[0] > 0)
        }
    }
    @Test func allOriginalInternalNodesAndHistoryStates() throws {
        let e = try make(model: ["rsh": 20, "cgso": 1e-10, "cgdo": 1e-10, "cgbo": 1e-10], instance: ["nrd": 1, "nrs": 1, "rbodymod": 1,
            "rgatemod": 3, "trnqsmod": 1, "acnqsmod": 1, "ad": 1e-12, "as": 1e-12, "pd": 4e-6, "ps": 4e-6])
        let t = e.topology
        #expect(t.nodeCount == 12)
        #expect(Set([t.drainPrime, t.sourcePrime, t.gatePrime, t.gateMid, t.bodyPrime, t.drainBody, t.sourceBody, t.chargeNode]).count == 8)
        try e.initializeHistory(at: bias(e))
        var trialBias = bias(e); trialBias[t.chargeNode] = 1e-3
        let result = try e.evaluate(bias: trialBias, analysis: .trapezoidal(timeStep: 1e-9))
        #expect(result.states[17] != 0 && result.states[21] != 0 && result.states[23] != 0)
        #expect(abs(result.states[25] - 1e-12) < 1e-25)
        #expect(result.states[29] == 0 && result.states[30] == 0 && result.states[31] == 0)
        for row in 0..<16 { for column in 0..<16 where row >= 13 || column >= 13 {
            #expect(result.realJacobian[row * 16 + column] == 0)
            #expect(result.imaginaryJacobian[row * 16 + column] == 0)
        }}
    }
    @Test func independentOriginalOperatingPointFixtures() throws {
        let url = try #require(Bundle.module.url(forResource: "reference", withExtension: "json", subdirectory: "Fixtures"))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(json["cases"] as? [[String: Any]])
        #expect(cases.count == 22)
        for fixture in cases {
            let p = try #require(fixture["polarity"] as? Int)
            let e = try BSIM4Evaluator(configuration: .init(polarity: p == 1 ? .nmos : .pmos,
                temperature: try #require(fixture["temperature"] as? Double), noiseRequested: true, maximumStressIterations: 8,
                modelParameters: try #require(fixture["modelParameters"] as? [String: Double]),
                instanceParameters: try #require(fixture["instanceParameters"] as? [String: Double])))
            let input = try #require(fixture["bias"] as? [Double])
            var v = SIMD16<Double>(repeating: 0)
            for index in 0..<13 { v[index] = input[index] }
            let result = try e.evaluate(bias: v, analysis: .dc, minimumJunctionConductance: 0)
            let expected = try #require(fixture["operatingPoint"] as? [Double])
            for index in 0..<7 { #expect(abs(result.operatingPoint[index] - expected[index]) <= 1e-13 + 2e-7 * abs(expected[index])) }
            let charges = try #require(fixture["intrinsicCharges"] as? [Double])
            for index in 0..<4 { #expect(abs(result.intrinsicCharges[index] - charges[index]) <= 1e-23 + 2e-7 * abs(charges[index])) }
        }
    }
    @Test func rejectedEvaluationPreservesHistoryAndInvalidatesToken() throws {
        let e = try make()
        var v = bias(e)
        #expect(throws: BSIM4Error.invalidHistory) { try e.acceptedStates() }
        try e.initializeHistory(at: v)
        let before = try e.acceptedStates()
        v[2] += 0.01
        let trial = try e.evaluate(bias: v, analysis: .backwardEuler(timeStep: 1e-9))
        #expect(try e.acceptedStates() == before)
        var bad = v; bad[15] = 1
        #expect(throws: BSIM4Error.self) { try e.evaluate(bias: bad, analysis: .dc) }
        #expect(throws: BSIM4Error.invalidHistory) { try e.commit(token: trial.token) }
        #expect(try e.acceptedStates() == before)
        let valid = try e.evaluate(bias: v, analysis: .trapezoidal(timeStep: 1e-9))
        try e.commit(token: valid.token)
        #expect(throws: BSIM4Error.invalidHistory) { try e.commit(token: valid.token) }
        #expect(try e.acceptedStates() != before)
    }
    @Test func numericalFailureRemainsTyped() throws {
        let e = try make()
        var v = bias(e); v[2] = 1e308
        #expect(throws: BSIM4Error.nonFiniteEvaluation) { try e.evaluate(bias: v, analysis: .dc) }
        v = bias(e); v[1] = .nan
        #expect(throws: BSIM4Error.self) { try e.initializeHistory(at: v) }
        #expect(throws: BSIM4Error.invalidHistory) { try e.acceptedStates() }
    }
    @Test func acNQSUsesOriginalComplexFrequencyResponse() throws {
        let e = try make(instance: ["trnqsmod": 1, "acnqsmod": 1])
        let low = try e.evaluate(bias: bias(e), analysis: .ac(angularFrequency: 1e3))
        let high = try e.evaluate(bias: bias(e), analysis: .ac(angularFrequency: 1e12))
        let index = e.topology.drainPrime * 16 + e.topology.gatePrime
        #expect(abs(low.realJacobian[index] - high.realJacobian[index]) > 1e-9)
        #expect(high.imaginaryJacobian[index] != 0)
    }
    @Test func concurrentEvaluationUsesOneStateOwner() async throws {
        let e = try make(instance: ["trnqsmod": 1, "acnqsmod": 1])
        let v = bias(e)
        try e.initializeHistory(at: v)
        let before = try e.acceptedStates()
        let expected = try e.evaluate(bias: v, analysis: .dc).operatingPoint[0]
        try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<64 { group.addTask { try e.evaluate(bias: v, analysis: .dc).operatingPoint[0] } }
            for try await value in group { #expect(value == expected) }
        }
        #expect(try e.acceptedStates() == before)
    }
}
