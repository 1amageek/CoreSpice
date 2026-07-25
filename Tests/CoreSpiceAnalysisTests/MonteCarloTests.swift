import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Monte Carlo Analysis Tests")
struct MonteCarloTests {

    /// Basic MC with Gaussian variation on R1.
    /// V1(5V) -> R1(1kΩ ± 10%) -> out -> R2(1kΩ) -> GND
    /// All results should be valid DC operating points.
    @Test func gaussianVariation() async throws {
        let (plan, devices) = try buildDivider()

        let variations = [
            ParameterVariation(
                deviceName: "R1",
                parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 100)  // 10% sigma
            )
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 10,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 42
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await mc.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(result.iterations == 10)
        #expect(result.results.count == 10)
        #expect(result.parameterValues.count == 10)
        #expect(result.seed == 42)

        // All results should produce valid voltages
        let out = Node(id: 2)
        for dcResult in result.results {
            let vout = try dcResult.voltage(at: out)
            // With R1 varying around 1kΩ and R2 = 1kΩ:
            // V(out) = 5 * R2 / (R1 + R2) should be in reasonable range
            #expect(vout > 1.0 && vout < 4.0)
        }

        // Results should not all be identical (randomness is working)
        let voltages = try result.results.map { try $0.voltage(at: out) }
        let minV = try #require(voltages.min())
        let maxV = try #require(voltages.max())
        #expect(maxV - minV > 0.001)
    }

    @Test func rejectZeroIterations() async throws {
        let (plan, devices) = try buildDivider()
        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 0,
            variations: [],
            analysisFactory: { DCAnalysis() },
            seed: 1
        )

        do {
            _ = try await mc.run(
                plan: plan,
                devices: devices,
                solver: SparseLUSolver(),
                observer: nil,
                cancellation: CancellationToken()
            )
            Issue.record("Expected invalid configuration for zero Monte Carlo iterations.")
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error,
                  message.contains("iterations") else {
                Issue.record("Expected invalid Monte Carlo iteration configuration, got \(error).")
                return
            }
        } catch {
            Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
        }
    }

    /// Uniform variation on R2.
    @Test func uniformVariation() async throws {
        let (plan, devices) = try buildDivider()

        let variations = [
            ParameterVariation(
                deviceName: "R2",
                parameterName: "r",
                nominalValue: 1000,
                distribution: .uniform(range: 100)  // ±100Ω
            )
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 10,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 123
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await mc.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(result.results.count == 10)

        // All sampled R2 values should be in [900, 1100]
        for params in result.parameterValues {
            let r2Value = params["R2.r"]
            #expect(r2Value != nil)
            if let r2Value = r2Value {
                #expect(r2Value >= 900 && r2Value <= 1100)
            }
        }
    }

    /// Seeded runs should be reproducible.
    @Test func reproducibility() async throws {
        let (plan, devices) = try buildDivider()

        let variations = [
            ParameterVariation(
                deviceName: "R1",
                parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 100)
            )
        ]

        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Run twice with the same seed
        let mc1 = MonteCarloAnalysis<DCAnalysis>(
            iterations: 5,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 999
        )
        let result1 = try await mc1.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        let mc2 = MonteCarloAnalysis<DCAnalysis>(
            iterations: 5,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 999
        )
        let result2 = try await mc2.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Parameter values should be identical
        for i in 0..<5 {
            let p1 = result1.parameterValues[i]
            let p2 = result2.parameterValues[i]
            for (key, value) in p1 {
                let otherValue = try #require(p2[key])
                #expect(abs(value - otherValue) < 1e-15)
            }
        }
    }

    /// Multiple parameter variations in the same run.
    @Test func multipleVariations() async throws {
        let (plan, devices) = try buildDivider()

        let variations = [
            ParameterVariation(
                deviceName: "R1",
                parameterName: "r",
                nominalValue: 1000,
                distribution: .gaussian(sigma: 50)
            ),
            ParameterVariation(
                deviceName: "R2",
                parameterName: "r",
                nominalValue: 1000,
                distribution: .uniform(range: 50)
            ),
        ]

        let mc = MonteCarloAnalysis<DCAnalysis>(
            iterations: 10,
            variations: variations,
            analysisFactory: { DCAnalysis() },
            seed: 77
        )

        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await mc.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(result.results.count == 10)

        // Each iteration should have both R1.r and R2.r
        for params in result.parameterValues {
            #expect(params["R1.r"] != nil)
            #expect(params["R2.r"] != nil)
        }
    }

    // MARK: - Helpers

    private func buildDivider() throws -> (ExecutionPlan, [any BoundDevice]) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(5.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1000)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        return (plan, devices)
    }
}
