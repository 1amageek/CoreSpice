import Testing
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
}
