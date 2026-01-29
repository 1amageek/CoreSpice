import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("CoreSpiceAnalysis Tests")
struct CoreSpiceAnalysisTests {

    // Helper: build a simple resistive divider circuit
    // V1(5V) -> R1(1kΩ) -> node2 -> R2(1kΩ) -> GND
    // Expected: V(node2) = 2.5V
    private func buildResistiveDivider() throws -> (ExecutionPlan, [any BoundDevice]) {
        var netlist = Netlist()
        let _ = netlist.node("1")
        let _ = netlist.node("2")
        let branch = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["1", "0"],
                                parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["2", "0"],
                                parameters: ["r": .real(1000)])

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(variableMap: plan.topology.variableMap,
                                     matrixDimension: plan.topology.dimension)
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        return (plan, devices)
    }

    @Test func convergenceConfigDefaults() {
        let config = ConvergenceConfig()
        #expect(config.abstol == 1e-12)
        #expect(config.reltol == 1e-3)
        #expect(config.vntol == 1e-6)
        #expect(config.maxIterations == 50)
        #expect(config.gmin == 1e-12)
    }

    @Test func convergenceCheck() {
        let config = ConvergenceConfig(reltol: 1e-3, vntol: 1e-6)
        // Small dx relative to x should converge
        let converged = config.isConverged(dx: [1e-8, 1e-8], x: [5.0, 2.5])
        #expect(converged)

        // Large dx should not converge
        let notConverged = config.isConverged(dx: [1.0, 0.5], x: [5.0, 2.5])
        #expect(!notConverged)
    }

    @Test func frequencySweepDecade() {
        let sweep = FrequencySweep.decade(start: 1.0, stop: 1000.0, pointsPerDecade: 10)
        let freqs = sweep.frequencies()
        #expect(freqs.count > 0)
        #expect(abs(freqs.first! - 1.0) < 1e-10)
        // Last frequency should be close to 1000
        #expect(freqs.last! >= 999.0)
    }

    @Test func frequencySweepLinear() {
        let sweep = FrequencySweep.linear(start: 100, stop: 200, points: 11)
        let freqs = sweep.frequencies()
        #expect(freqs.count == 11)
        #expect(abs(freqs[0] - 100.0) < 1e-10)
        #expect(abs(freqs[10] - 200.0) < 1e-10)
        #expect(abs(freqs[5] - 150.0) < 1e-10)
    }

    @Test func frequencySweepSingle() {
        let sweep = FrequencySweep.single(1000.0)
        let freqs = sweep.frequencies()
        #expect(freqs.count == 1)
        #expect(freqs[0] == 1000.0)
    }

    @Test func gminSteppingValues() {
        let gmin = GminStepping()
        let values = gmin.gminValues()
        #expect(values.count > 0)
        #expect(values.first! > values.last!)
    }

    @Test func sourceSteppingFactors() {
        let ss = SourceStepping(steps: 10)
        let factors = ss.sourceFactors()
        #expect(factors.count == 10)
        #expect(abs(factors.last! - 1.0) < 1e-10)
        #expect(abs(factors.first! - 0.1) < 1e-10)
    }

    @Test func lteEstimatorBasic() {
        let estimator = LTEEstimator()
        let lte = estimator.estimate(
            current: [1.0, 2.0],
            previous: [0.9, 1.8],
            twoPrevious: nil,
            timeStep: 1e-3,
            previousTimeStep: nil,
            method: .backwardEuler
        )
        #expect(lte > 0)
    }

    @Test func breakpointManagerConstrainsStep() {
        var mgr = BreakpointManager()
        mgr.addBreakpoints([1e-3, 2e-3, 5e-3])

        let step1 = mgr.constrainTimeStep(currentTime: 0, proposedStep: 2e-3)
        #expect(step1 <= 1e-3 + 1e-15)

        let step2 = mgr.constrainTimeStep(currentTime: 1e-3, proposedStep: 5e-3)
        #expect(step2 <= 1e-3 + 1e-15)
    }

    @Test func cancellationToken() {
        let token = CancellationToken()
        #expect(!token.isCancelled)
        token.cancel()
        #expect(token.isCancelled)
    }

    @Test func transientConfigDefaults() {
        let config = TransientConfig(stopTime: 1e-3)
        #expect(config.stopTime == 1e-3)
        #expect(config.maxTimeStep > 0)
        #expect(config.minTimeStep > 0)
        #expect(config.lteTolerance > 0)
    }

    // MARK: - Integration Tests: Full Circuit Simulation

    /// DC Analysis: Resistive voltage divider
    /// V1(5V) -> R1(1kΩ) -> node2 -> R2(1kΩ) -> GND
    /// Expected: V(node2) = 2.5V
    @Test func dcAnalysisResistiveDivider() async throws {
        let (plan, devices) = try buildResistiveDivider()

        let dcAnalysis = DCAnalysis()
        var solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // V(node1) should be 5V (voltage source)
        let node1 = Node(id: 1)
        let v1 = result.voltage(at: node1)
        #expect(abs(v1 - 5.0) < 1e-9, "V(node1) should be 5V, got \(v1)")

        // V(node2) should be 2.5V (voltage divider)
        let node2 = Node(id: 2)
        let v2 = result.voltage(at: node2)
        #expect(abs(v2 - 2.5) < 1e-6, "V(node2) should be 2.5V, got \(v2)")

        // Should converge in few iterations for linear circuit
        #expect(result.iterations <= 5, "Linear circuit should converge quickly")
    }

    /// DC Analysis: Diode circuit with nonlinear convergence
    /// V1(1V) -> R1(1kΩ) -> node2 -> D1 -> GND
    /// Expected: V(node2) ≈ 0.6-0.7V (diode forward voltage)
    @Test func dcAnalysisDiodeCircuit() async throws {
        var netlist = Netlist()
        let _ = netlist.node("1")
        let _ = netlist.node("2")
        let branch = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["1", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["2", "0"],
                                parameters: [:])  // Use default diode parameters

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(variableMap: plan.topology.variableMap,
                                     matrixDimension: plan.topology.dimension)
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let dcAnalysis = DCAnalysis()
        var solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // V(node2) should be around 0.6-0.7V (typical diode forward voltage)
        let node2 = Node(id: 2)
        let v2 = result.voltage(at: node2)
        #expect(v2 > 0.5 && v2 < 0.8, "Diode forward voltage should be ~0.6-0.7V, got \(v2)")

        // Diode current: I = (V1 - Vd) / R1 ≈ (1.0 - 0.65) / 1000 ≈ 0.35mA
        let node1 = Node(id: 1)
        let v1 = result.voltage(at: node1)
        let diodeCurrent = (v1 - v2) / 1000.0
        #expect(diodeCurrent > 0.0002 && diodeCurrent < 0.0005,
                "Diode current should be ~0.3-0.4mA, got \(diodeCurrent * 1000) mA")
    }

    /// AC Analysis: Verify AC analysis runs without error
    /// Note: Full AC stimulus functionality requires additional voltage source parameters
    @Test func acAnalysisRuns() async throws {
        var netlist = Netlist()
        let _ = netlist.node("1")
        let _ = netlist.node("2")

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["1", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["2", "0"],
                                parameters: ["c": .real(1e-6)])

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(variableMap: plan.topology.variableMap,
                                     matrixDimension: plan.topology.dimension)
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let sweep = FrequencySweep.decade(start: 10.0, stop: 1000.0, pointsPerDecade: 5)
        let acAnalysis = ACAnalysis(sweep: sweep)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        // Verify AC analysis completes without throwing
        let result = try await acAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Verify we got results for all frequency points
        #expect(result.frequencies.count > 0, "Should have frequency points")
        #expect(result.solutions.count == result.frequencies.count, "Should have solution for each frequency")
    }

    /// Transient Analysis: RC circuit time-stepping
    /// V1(1V) -> R1(1kΩ) -> node2 -> C1(1µF) -> GND
    /// Verifies transient simulation produces time points and stable solution
    @Test func transientAnalysisRCCircuit() async throws {
        var netlist = Netlist()
        let n1 = netlist.node("n1")
        let n2 = netlist.node("n2")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["n1", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["n1", "n2"],
                                parameters: ["r": .real(1000)])  // 1kΩ
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["n2", "0"],
                                parameters: ["c": .real(1e-6)])  // 1µF

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(variableMap: plan.topology.variableMap,
                                     matrixDimension: plan.topology.dimension)
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        // Simulate for 1ms
        let transientConfig = TransientConfig(
            stopTime: 1e-3,
            maxTimeStep: 1e-4,
            initialTimeStep: 1e-5
        )
        let transientAnalysis = TransientAnalysis(config: transientConfig)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await transientAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Verify we have time points
        #expect(result.timePoints.count > 5, "Should have multiple time points")
        #expect(result.timePoints.first == 0.0, "Should start at t=0")
        #expect(result.timePoints.last! >= 0.9e-3, "Should reach near stop time")

        // Verify solution is stable (n2 voltage should be 1V at DC equilibrium)
        let finalVoltage = result.voltage(at: n2, timeIndex: result.timePoints.count - 1)
        #expect(abs(finalVoltage - 1.0) < 0.1, "Final voltage should be ≈1V, got \(finalVoltage)")

        // Verify time is monotonically increasing
        for i in 1..<result.timePoints.count {
            #expect(result.timePoints[i] > result.timePoints[i-1], "Time should increase")
        }
    }

    /// DC Analysis: Series resistor circuit (sanity check for larger circuits)
    /// Uses the same pattern as buildResistiveDivider which is known to work
    @Test func dcAnalysisSeriesResistors() async throws {
        // Use the same setup pattern as the working buildResistiveDivider helper
        var netlist = Netlist()
        // Explicitly create all nodes first (matching buildResistiveDivider pattern)
        let n1 = netlist.node("n1")
        let n2 = netlist.node("n2")
        let n3 = netlist.node("n3")
        let _ = netlist.branch()  // Allocate a branch for voltage source (matching helper pattern)

        // V1(10V) -> n1 -> R1(1kΩ) -> n2 -> R2(2kΩ) -> n3 -> R3(3kΩ) -> GND
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["n1", "0"],
                                parameters: ["v": .real(10.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["n1", "n2"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["n2", "n3"],
                                parameters: ["r": .real(2000)])
        try netlist.addInstance(name: "R3", typeName: "resistor", nodes: ["n3", "0"],
                                parameters: ["r": .real(3000)])

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(variableMap: plan.topology.variableMap,
                                     matrixDimension: plan.topology.dimension)
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let dcAnalysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Total resistance = 6kΩ, current = 10V / 6kΩ = 1.667mA
        // V(n2) = V(n3) + I × R2 = 5V + 1.667mA × 2kΩ = 8.333V
        // V(n3) = I × R3 = 1.667mA × 3kΩ = 5V
        let v2 = result.voltage(at: n2)
        let v3 = result.voltage(at: n3)

        let expectedV3 = 10.0 * 3.0 / 6.0  // 5V
        let expectedV2 = 10.0 * 5.0 / 6.0  // 8.333V

        #expect(abs(v3 - expectedV3) < 1e-6, "V(n3) should be 5V, got \(v3)")
        #expect(abs(v2 - expectedV2) < 1e-6, "V(n2) should be 8.333V, got \(v2)")
    }
}
