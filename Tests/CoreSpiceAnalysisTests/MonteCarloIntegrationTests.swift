import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Monte Carlo Integration Tests")
struct MonteCarloIntegrationTests {

    // MARK: - Helper

    private func buildDivider() throws -> (ExecutionPlan, [any BoundDevice]) {
        let (netlist, _) = CircuitFactory.resistiveDivider(v: 5.0, r1: 1000, r2: 1000)
        return try CircuitFactory.compile(netlist)
    }

    // MARK: - G7: Determinism for a fixed seed

    @Test("G7: Monte Carlo is reproducible for a fixed seed",
          .timeLimit(.minutes(1)))
    func monteCarloDeterministic() async throws {
        let (netlist, mid) = CircuitFactory.resistiveDivider(v: 5.0, r1: 1000, r2: 1000)
        let variations = [
            ParameterVariation(deviceName: "R1", parameterName: "r",
                               nominalValue: 1000, distribution: .gaussian(sigma: 100)),
            ParameterVariation(deviceName: "R2", parameterName: "r",
                               nominalValue: 1000, distribution: .gaussian(sigma: 100)),
        ]
        func runOnce() async throws -> [Double] {
            let (plan, devices) = try CircuitFactory.compile(netlist)
            let mc = MonteCarloAnalysis<DCAnalysis>(
                iterations: 25, variations: variations,
                analysisFactory: { DCAnalysis() }, seed: 7
            )
            let r = try await mc.run(
                plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken()
            )
            return r.results.map { $0.voltage(at: mid) }
        }
        let a = try await runOnce()
        let b = try await runOnce()
        #expect(a.count == 25 && b.count == 25)
        // Same seed must reproduce identical results bit-for-bit.
        for (x, y) in zip(a, b) {
            #expect(x == y, "same seed must give identical results: \(x) vs \(y)")
        }
        // And the variation actually produced spread across iterations.
        #expect(Set(a).count > 1, "results should vary across iterations")
    }

    // MARK: - G4: Nonlinear Circuit MC

    @Test("G4: Monte Carlo on diode circuit",
          .timeLimit(.minutes(1)))
    func diodeCircuitMC() async throws {
        let (netlist, _) = CircuitFactory.diodeCircuit(v: 5.0, r: 1000)
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let variations = [
            ParameterVariation(
                deviceName: "R1", parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 100)
            )
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 20,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 42
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()
        let result = try await mc.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        #expect(result.results.count == 20)
        // Diode forward voltage should vary but stay in physical range
        let anode = Node(id: 2)
        for dcResult in result.results {
            let v = dcResult.voltage(at: anode)
            #expect(v > 0.3 && v < 0.9, "Diode Vf should be in range, got \(v)")
        }
    }

    // MARK: - G5: Multiple Parameter Simultaneous Variation

    @Test("G5: Simultaneous Gaussian variation on two resistors")
    func multipleGaussianVariation() async throws {
        let (plan, devices) = try buildDivider()

        let variations = [
            ParameterVariation(
                deviceName: "R1", parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 100)
            ),
            ParameterVariation(
                deviceName: "R2", parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 100)
            ),
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 30,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 12345
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()
        let result = try await mc.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        #expect(result.results.count == 30)
        #expect(result.parameterValues.count == 30)

        let out = Node(id: 2)
        var voltages: [Double] = []
        for dcResult in result.results {
            let v = dcResult.voltage(at: out)
            voltages.append(v)
            // V(out) = 5 × R2/(R1+R2) - with variations, should stay reasonable
            #expect(v > 1.0 && v < 4.0, "V(out) should be in reasonable range, got \(v)")
        }

        // Each iteration should have both R1.r and R2.r sampled values
        for params in result.parameterValues {
            #expect(params["R1.r"] != nil)
            #expect(params["R2.r"] != nil)
        }

        // Compute mean and verify it's near nominal
        let mean = voltages.reduce(0.0, +) / Double(voltages.count)
        #expect(abs(mean - 2.5) < 0.3,
                "Mean output should be near 2.5V, got \(mean)")

        // Verify spread: standard deviation should be nonzero
        let variance = voltages.map { ($0 - mean) * ($0 - mean) }.reduce(0.0, +) / Double(voltages.count)
        let stddev = sqrt(variance)
        #expect(stddev > 0.01, "Should have nonzero spread, stddev=\(stddev)")
    }

    // MARK: - G6: BJT β Variation

    @Test("G6: Monte Carlo on BJT with beta variation",
          .timeLimit(.minutes(1)))
    func bjtBetaVariation() async throws {
        let (netlist, col, _) = CircuitFactory.bjtCommonEmitter(
            vcc: 12.0, rc: 2000, vbb: 1.5, rb: 100_000,
            bjtParams: ["is": .real(1e-16), "bf": .real(100)]
        )
        let (plan, devices) = try CircuitFactory.compile(netlist)

        let variations = [
            ParameterVariation(
                deviceName: "Q1", parameterName: "bf",
                nominalValue: 100,
                distribution: .gaussian(sigma: 30)
            )
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 20,
            variations: variations,
            analysisFactory: { DCAnalysis(config: CircuitFactory.nonlinearConfig) },
            seed: 99
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()
        let result = try await mc.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        #expect(result.results.count == 20)
        for dcResult in result.results {
            let vCol = dcResult.voltage(at: col)
            #expect(vCol > 0 && vCol < 12.0)
        }
    }

    // MARK: - G7: Large Iteration Count

    @Test("G7: Monte Carlo with 100 iterations for statistical convergence")
    func largeIterationCount() async throws {
        let (plan, devices) = try buildDivider()

        let variations = [
            ParameterVariation(
                deviceName: "R1", parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 100)
            )
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 100,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 7777
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()
        let result = try await mc.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        #expect(result.results.count == 100)

        let out = Node(id: 2)
        let voltages = result.results.map { $0.voltage(at: out) }

        // Mean should converge to ~2.5V with 100 samples
        let mean = voltages.reduce(0.0, +) / Double(voltages.count)
        #expect(abs(mean - 2.5) < 0.15,
                "Mean should converge near 2.5V with 100 iterations, got \(mean)")

        // Standard deviation should be reasonable (not zero, not huge)
        let variance = voltages.map { ($0 - mean) * ($0 - mean) }.reduce(0.0, +) / Double(voltages.count)
        let stddev = sqrt(variance)
        #expect(stddev > 0.01 && stddev < 1.0,
                "Stddev should be reasonable, got \(stddev)")

        // Min and max should span a range
        let minV = voltages.min()!
        let maxV = voltages.max()!
        #expect(maxV - minV > 0.1, "Range should show variation")
    }
}
