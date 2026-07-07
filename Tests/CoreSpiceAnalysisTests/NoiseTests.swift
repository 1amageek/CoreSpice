import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Noise Analysis Tests")
struct NoiseTests {

    /// Boltzmann constant (J/K).
    private static let kB: Double = 1.380649e-23
    /// Default temperature (300K).
    private static let temperature: Double = 300.0

    /// Single resistor noise: V1(1V) -> R1(1kΩ) -> out -> R2(1kΩ) -> GND
    /// The output-referred thermal noise from each resistor can be computed analytically.
    ///
    /// For this divider, the output noise voltage PSD = 4kT * R_parallel
    /// where R_parallel = R1‖R2 = 500Ω (for equal resistors).
    /// S_v(f) = 4kT * R_parallel = 4 * 1.38e-23 * 300 * 500 = 8.28e-18 V²/Hz
    @Test func resistiveDividerNoise() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1.0)]
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

        let sweep = FrequencySweep.linear(start: 100, stop: 10000, points: 10)
        let noiseAnalysis = NoiseAnalysis(
            outputNode: out,
            sweep: sweep
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await noiseAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(result.frequencies.count == 10)
        #expect(result.outputNoiseDensity.count == 10)

        // Theoretical output noise PSD for a divider with equal resistors:
        // S_v_out = 4kT * (R1‖R2) = 4kT * 500
        let theoreticalPSD = 4.0 * Self.kB * Self.temperature * 500.0

        // All frequency points should have approximately the same noise PSD
        // (white noise from resistors is frequency-independent)
        for psd in result.outputNoiseDensity {
            let ratio = psd / theoreticalPSD
            #expect(ratio > 0.5 && ratio < 2.0)
        }

        // Integrated noise should be positive
        #expect(result.integratedOutputNoise > 0)
    }

    /// Verify device noise contributions are tracked individually.
    @Test func deviceContributionsTracked() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1.0)]
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

        let sweep = FrequencySweep.single(1000.0)
        let noiseAnalysis = NoiseAnalysis(
            outputNode: out,
            sweep: sweep
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await noiseAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Should have contributions from R1 and R2
        #expect(result.deviceContributions.count == 2)

        let r1Contrib = result.deviceContributions.first(where: { $0.noiseName == "R1_thermal" })
        let r2Contrib = result.deviceContributions.first(where: { $0.noiseName == "R2_thermal" })
        #expect(r1Contrib != nil)
        #expect(r2Contrib != nil)

        // Both should have positive spectral density
        #expect(r1Contrib!.spectralDensity[0] > 0)
        #expect(r2Contrib!.spectralDensity[0] > 0)

        // Sum of contributions should equal total
        let sum = r1Contrib!.spectralDensity[0] + r2Contrib!.spectralDensity[0]
        #expect(abs(sum - result.outputNoiseDensity[0]) < 1e-30)
    }

    /// Higher resistance should produce more output noise.
    @Test func higherResistanceMoreNoise() async throws {
        let solver = SparseLUSolver()
        let token = CancellationToken()
        let sweep = FrequencySweep.single(1000.0)

        // Circuit 1: R = 1kΩ
        let result1kOhm = try await runNoiseForResistor(
            resistance: 1000, sweep: sweep, solver: solver, token: token
        )

        // Circuit 2: R = 10kΩ
        let result10kOhm = try await runNoiseForResistor(
            resistance: 10000, sweep: sweep, solver: solver, token: token
        )

        // Higher resistance should produce higher output noise
        #expect(result10kOhm.outputNoiseDensity[0] > result1kOhm.outputNoiseDensity[0])
    }

    @Test func inputReferredNoiseUsesInputSourceGain() async throws {
        let result = try await runNoiseForResistor(
            resistance: 1000,
            sweep: .single(1000.0),
            solver: SparseLUSolver(),
            token: CancellationToken(),
            inputSourceName: "V1"
        )

        let outputNoise = result.outputNoiseDensity[0]
        let inputReferredNoise = result.inputReferredNoiseDensity[0]
        #expect(inputReferredNoise > outputNoise)
        #expect(abs((inputReferredNoise / outputNoise) - 4.0) < 0.1)
    }

    @Test func inputReferredNoiseRejectsUnknownInputSource() async throws {
        do {
            _ = try await runNoiseForResistor(
                resistance: 1000,
                sweep: .single(1000.0),
                solver: SparseLUSolver(),
                token: CancellationToken(),
                inputSourceName: "MISSING"
            )
            Issue.record("Expected AnalysisError.invalidConfiguration.")
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
                return
            }
            #expect(message.contains("Input source 'MISSING' not found in circuit"))
        } catch {
            Issue.record("Expected AnalysisError.invalidConfiguration, got \(error).")
        }
    }

    // MARK: - Helpers

    private func runNoiseForResistor(
        resistance: Double,
        sweep: FrequencySweep,
        solver: SparseLUSolver,
        token: CancellationToken,
        inputSourceName: String? = nil
    ) async throws -> NoiseResult {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(resistance)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(resistance)]
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

        let noiseAnalysis = NoiseAnalysis(outputNode: out, inputSourceName: inputSourceName, sweep: sweep)
        return try await noiseAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )
    }
}
