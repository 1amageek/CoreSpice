import Foundation
import Testing
import CoreSpiceCompactModels

@Suite("Native BSIM3 kernel", .timeLimit(.minutes(1)))
struct BSIM3KernelTests {
    private func configuration(_ polarity: BSIM3Configuration.Polarity = .nmos,
                               capmod: Double = 3, extras: [String: Double] = [:],
                               instance: [String: Double] = [:]) -> BSIM3Configuration {
        var model: [String: Double] = ["vth0": polarity == .nmos ? 0.7 : -0.7, "u0": 500, "tox": 10e-9,
                                      "capmod": capmod, "cj": 1e-3, "cjsw": 1e-10, "cgdo": 2e-10, "cgso": 3e-10]
        model.merge(extras) { _, new in new }
        var geometry: [String: Double] = ["w": 10e-6, "l": 1e-6, "ad": 2e-12, "as": 3e-12, "pd": 12e-6, "ps": 14e-6]
        geometry.merge(instance) { _, new in new }
        return .init(polarity: polarity, modelParameters: model, instanceParameters: geometry)
    }

    private func close(_ actual: Double, _ expected: Double, relative: Double = 3e-4, absolute: Double = 1e-12,
                       context: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected)),
                "\(context) actual=\(actual), expected=\(expected)", sourceLocation: sourceLocation)
    }

    @Test func independentNgspiceFixturesAgree() throws {
        struct Oracle: Decodable {
            struct Case: Decodable {
                let name: String
                let polarity: String
                let bias: [Double]
                let temperature: Double
                let capmod: Double
                let expected: [String: Double]
            }
            let cases: [Case]
        }
        let path = try #require(Bundle.module.url(forResource: "oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: path))
        #expect(oracle.cases.count == 18)
        for fixture in oracle.cases {
            var config = configuration(fixture.polarity == "nmos" ? .nmos : .pmos, capmod: fixture.capmod)
            config.temperature = fixture.temperature
            let model = try BSIM3Evaluator(configuration: config)
            var bias = SIMD8<Double>(repeating: 0)
            for index in 0..<8 { bias[index] = fixture.bias[index] }
            let result = try model.evaluate(bias: bias, analysis: .dc)
            for (index, key) in ["id", "gm", "gds", "gmbs"].enumerated() {
                close(result.operatingPoint[index], try #require(fixture.expected[key]), relative: 2e-10, absolute: 1e-20,
                      context: fixture.name + " " + key)
            }
            // Original query values are normalized charge states. Public charges
            // convert them to physical polarity, while preserving state order.
            for (slot, key) in [(6, "qg"), (8, "qd"), (4, "qb")] {
                close(result.states[slot], try #require(fixture.expected[key]), relative: 2e-10, absolute: 1e-26,
                      context: fixture.name + " " + key)
            }
        }
    }

    @Test func coldOfficialPhysics() throws {
        let model = try BSIM3Evaluator(configuration: configuration())
        let result = try model.evaluate(bias: SIMD8(0, 1, 1.2, 0, 0, 0, 0, 0), analysis: .dc)
        #expect(result.residual[1] > 0)
        #expect(result.operatingPoint[1] > 0)
        #expect(model.topology.nodeCount == 4)
        #expect(result.charge[2] > 0)
        close((1...4).reduce(0) { $0 + result.residual[$1] }, 0, absolute: 1e-17)
        close((1...4).reduce(0) { $0 + result.charge[$1] }, 0, absolute: 1e-28)
    }

    @Test func terminalJacobiansMatchFiniteDifferences() throws {
        for polarity in [BSIM3Configuration.Polarity.nmos, .pmos] {
            let sign = Double(polarity.rawValue)
            for capmod in [0.0, 1.0, 2.0, 3.0] {
                let model = try BSIM3Evaluator(configuration: configuration(polarity, capmod: capmod))
                // Cutoff, near threshold, linear, saturation, reverse, body-forward and common-mode bias.
                for point in [(0.1, 0.1, -0.2), (0.1, 0.7, -0.1), (0.1, 1.2, -0.2),
                              (1.0, 1.2, -0.2), (-0.5, 1.2, -0.2), (0.2, 1.0, 0.05)] {
                    let bias = SIMD8<Double>(0, sign * point.0 + 0.3, sign * point.1 + 0.3,
                                             0.3, sign * point.2 + 0.3, 0, 0, 0)
                    let dc = try model.evaluate(bias: bias, analysis: .dc)
                    let ac = try model.evaluate(bias: bias, analysis: .ac(angularFrequency: 1))
                    for column in 1...4 {
                        var plus = bias, minus = bias
                        plus[column] += 1e-6; minus[column] -= 1e-6
                        let p = try model.evaluate(bias: plus, analysis: .dc)
                        let m = try model.evaluate(bias: minus, analysis: .dc)
                        for row in 1...4 {
                            close(dc.realJacobian[row * 8 + column], (p.residual[row] - m.residual[row]) / 2e-6)
                            close(ac.realJacobian[row * 8 + column], dc.realJacobian[row * 8 + column])
                            close(ac.imaginaryJacobian[row * 8 + column], (p.charge[row] - m.charge[row]) / 2e-6,
                                  absolute: 1e-20, context: "capmod=\(capmod) point=\(point) row=\(row) col=\(column)")
                        }
                    }
                }
            }
        }
    }

    @Test func seriesNodesRemainExplicit() throws {
        let model = try BSIM3Evaluator(configuration: configuration(extras: ["rsh": 20], instance: ["nrd": 2, "nrs": 3]))
        #expect(model.topology.nodeCount == 6)
        #expect(model.topology.drainPrime == 5)
        #expect(model.topology.sourcePrime == 6)
        let bias = SIMD8<Double>(0, 1, 1.2, 0, -0.1, 0.8, 0.05, 0)
        let dc = try model.evaluate(bias: bias, analysis: .dc)
        close(dc.residual[1], 0.2 / 40, absolute: 1e-16)
        close(dc.residual[3], -0.05 / 60, absolute: 1e-16)
        let ac = try model.evaluate(bias: bias, analysis: .ac(angularFrequency: 1))
        for col in 1...6 {
            var plus = bias, minus = bias
            plus[col] += 1e-6; minus[col] -= 1e-6
            let p = try model.evaluate(bias: plus, analysis: .dc)
            let m = try model.evaluate(bias: minus, analysis: .dc)
            for row in 1...6 {
                close(dc.realJacobian[row * 8 + col], (p.residual[row] - m.residual[row]) / 2e-6)
                close(ac.imaginaryJacobian[row * 8 + col], (p.charge[row] - m.charge[row]) / 2e-6, absolute: 1e-20)
            }
        }
        #expect(dc.charge[1] == 0)
        #expect(dc.charge[5] != 0)
    }

    @Test func nonQuasistaticStatesAndACRemainNative() throws {
        for acnqs in [0.0, 1.0] {
            let model = try BSIM3Evaluator(configuration: configuration(extras: ["rsh": 20, "acnqsmod": acnqs],
                                                                       instance: ["nqsmod": 1]))
            #expect(model.topology.nodeCount == 7)
            #expect(model.topology.chargeNode == 7)
            let initial = SIMD8<Double>(0, 1, 1.2, 0, -0.1, 0.95, 0.02, 0)
            let low = try model.evaluate(bias: initial, analysis: .ac(angularFrequency: 1e3))
            let high = try model.evaluate(bias: initial, analysis: .ac(angularFrequency: 1e12))
            #expect(low.states[12] != 0)
            #expect(high.imaginaryJacobian[2 * 8 + 2] != 0)
            if acnqs == 0 {
                #expect(low.realJacobian[7 * 8 + 7] > 0)
                close(high.imaginaryJacobian[7 * 8 + 7], 1e3, relative: 1e-12)
            } else {
                #expect(low.realJacobian[7 * 8 + 7] == 1)
                #expect(high.realJacobian[2 * 8 + 2] != low.realJacobian[2 * 8 + 2])
            }
            try model.initializeHistory(at: initial)
            var changed = initial
            changed[2] += 0.1; changed[7] = 1e-6
            let trial = try model.evaluate(bias: changed, analysis: .backwardEuler(timeStep: 1e-9))
            #expect(trial.states[14] != 0)
            #expect(trial.states[15] != 0)
            #expect(trial.realJacobian[7 * 8 + 7] > 0)
            try model.commit(token: trial.token)
            #expect(model.acceptedStates()[14] == trial.states[14])
        }
    }

    @Test func nqsTransientJacobianMatchesFiniteDifferences() throws {
        for polarity in [BSIM3Configuration.Polarity.nmos, .pmos] {
            let sign = Double(polarity.rawValue)
            let model = try BSIM3Evaluator(configuration: configuration(polarity, extras: ["rsh": 20], instance: ["nqsmod": 1]))
            let initial = SIMD8<Double>(0, sign, sign * 1.2, 0, -sign * 0.1, sign * 0.95, sign * 0.02, 0)
            try model.initializeHistory(at: initial)
            var changed = initial; changed[2] += sign * 0.1; changed[7] = sign * 1e-6
            for analysis in [BSIM3Analysis.backwardEuler(timeStep: 1e-9), .trapezoidal(timeStep: 2e-9)] {
                let trial = try model.evaluate(bias: changed, analysis: analysis)
                for column in 1...7 {
                    var plus = changed, minus = changed
                    plus[column] += 1e-6; minus[column] -= 1e-6
                    let p = try model.evaluate(bias: plus, analysis: analysis)
                    let m = try model.evaluate(bias: minus, analysis: analysis)
                    for row in 1...7 {
                        close(trial.realJacobian[row * 8 + column], (p.residual[row] - m.residual[row]) / 2e-6,
                              absolute: 1e-10, context: "NQS row=\(row) col=\(column)")
                    }
                }
            }
        }
    }

    @Test func acceptedHistoryUsesBEAndTrapezoidal() throws {
        let model = try BSIM3Evaluator(configuration: configuration())
        let initial = SIMD8<Double>(0, 1, 1.0, 0, -0.1, 0, 0, 0)
        let q0 = try model.evaluate(bias: initial, analysis: .dc).charge
        try model.initializeHistory(at: initial)
        let history = model.acceptedStates()
        var first = initial; first[2] = 1.1
        let dc1 = try model.evaluate(bias: first, analysis: .dc)
        let be = try model.evaluate(bias: first, analysis: .backwardEuler(timeStep: 1e-9))
        for row in 1...4 { close(be.residual[row] - dc1.residual[row], (be.charge[row] - q0[row]) / 1e-9, absolute: 1e-12) }
        #expect(model.acceptedStates() == history)
        let superseded = try model.evaluate(bias: first, analysis: .backwardEuler(timeStep: 2e-9))
        #expect(throws: BSIM3Error.invalidHistory) { try model.commit(token: be.token) }
        try model.commit(token: superseded.token)
        #expect(throws: BSIM3Error.invalidHistory) { try model.commit(token: superseded.token) }
        let accepted = model.acceptedStates()
        #expect(accepted[6] == superseded.states[6])
        var second = first; second[2] = 1.15
        let dc2 = try model.evaluate(bias: second, analysis: .dc)
        let trap = try model.evaluate(bias: second, analysis: .trapezoidal(timeStep: 1e-9))
        for row in 1...4 {
            let prior = superseded.residual[row] - dc1.residual[row]
            close(trap.residual[row] - dc2.residual[row], 2 * (trap.charge[row] - superseded.charge[row]) / 1e-9 - prior)
        }
        #expect(model.acceptedStates() == accepted)
        try model.commit(token: trap.token)
        #expect(model.acceptedStates()[7] == trap.states[7])
    }

    @Test func invalidConfigurationAndNumericalFailureAreExplicit() throws {
        #expect(throws: BSIM3Error.unsupportedVersion("3.2")) { try BSIM3Evaluator(configuration: .init(version: "3.2")) }
        for model in [["unknown": 1.0], ["capmod": 4], ["acnqsmod": 2], ["mobmod": 1.5], ["tox": -1e-9], ["dvt1": -1]] {
            #expect(throws: BSIM3Error.self) { try BSIM3Evaluator(configuration: .init(modelParameters: model)) }
        }
        for instance in [["l": 0.0], ["w": -1], ["gm": 1], ["nqsmod": 2], ["ad": -1]] {
            #expect(throws: BSIM3Error.self) { try BSIM3Evaluator(configuration: .init(instanceParameters: instance)) }
        }
        #expect(throws: BSIM3Error.self) { try BSIM3Evaluator(configuration: .init(modelParameters: ["lint": 1e-5])) }
        do {
            _ = try BSIM3Evaluator(configuration: .init(modelParameters: ["lint": 1e-5]))
            Issue.record("Invalid effective geometry was accepted")
        } catch BSIM3Error.modelRejected(let diagnostics) {
            #expect(diagnostics.contains("mosfet M1, model CoreSpiceBSIM3"))
        }
        let model = try BSIM3Evaluator(configuration: configuration())
        let bias = SIMD8<Double>(0, 1, 1.2, 0, 0, 0, 0, 0)
        #expect(throws: BSIM3Error.invalidHistory) { try model.evaluate(bias: bias, analysis: .backwardEuler(timeStep: 1e-9)) }
        try model.initializeHistory(at: bias)
        let history = model.acceptedStates()
        var invalid = bias; invalid[1] = .nan
        #expect(throws: BSIM3Error.self) { try model.evaluate(bias: invalid, analysis: .dc) }
        var overflow = bias; overflow[4] = 1e200
        #expect(throws: BSIM3Error.nonFiniteEvaluation) { try model.evaluate(bias: overflow, analysis: .dc) }
        #expect(model.acceptedStates() == history)
        #expect(throws: BSIM3Error.invalidHistory) { try model.evaluate(bias: bias, analysis: .trapezoidal(timeStep: 0)) }
    }

    @Test func diagnosticsCaptureOriginalAdjustments() throws {
        let model = try BSIM3Evaluator(configuration: configuration(extras: ["pb": 0.01, "a2": 0, "paramchk": 1]))
        #expect(model.diagnostics.contains { $0.message.contains("Pb is set to 0.1") })
        #expect(model.diagnostics.contains { $0.message.contains("A2") && $0.severity == .warning })
        let result = try model.evaluate(bias: SIMD8(0, 1, 1.2, 0, 0, 0, 0, 0), analysis: .dc)
        #expect(result.residual[1] > 0)
    }

    @Test func concurrentOwnersAndOneOwnerStayIsolated() async throws {
        let shared = try BSIM3Evaluator(configuration: configuration())
        let bias = SIMD8<Double>(0, 1, 1.2, 0, -0.1, 0, 0, 0)
        let reference = try shared.evaluate(bias: bias, analysis: .dc).residual
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let local = try BSIM3Evaluator(configuration: configuration(index.isMultiple(of: 2) ? .nmos : .pmos))
                    for _ in 0..<32 {
                        let value = try shared.evaluate(bias: bias, analysis: .dc)
                        #expect(value.residual == reference)
                        let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
                        let other = try local.evaluate(bias: bias * sign, analysis: .dc)
                        #expect(other.residual[1] * sign > 0)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
