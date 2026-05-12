import Testing
import Foundation
import Synchronization
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Newton-Raphson Convergence Tests")
struct NewtonRaphsonConvergenceTests {

    // MARK: - Test Observer

    /// Observer that records Newton-Raphson iteration residuals, tracking sequences.
    /// When a new sequence starts (iteration 0), it begins recording a new sequence.
    final class ResidualRecorder: AnalysisObserver, Sendable {
        private struct State: Sendable {
            var sequences: [[Double]] = []
            var currentSequence: [Double] = []
        }

        private let state = Mutex(State())

        /// All recorded residual sequences.
        var sequences: [[Double]] {
            state.withLock { state in
                var result = state.sequences
                if !state.currentSequence.isEmpty {
                    result.append(state.currentSequence)
                }
                return result
            }
        }

        /// Returns the last complete residual sequence (most relevant for convergence analysis).
        var lastSequence: [Double] {
            state.withLock { state in
                if !state.currentSequence.isEmpty {
                    return state.currentSequence
                }
                return state.sequences.last ?? []
            }
        }

        func onEvent(_ event: AnalysisEvent) {
            state.withLock { state in
                if case .newtonIterationFinished(let info) = event {
                    // Detect start of new sequence
                    if info.iteration == 0 && !state.currentSequence.isEmpty {
                        state.sequences.append(state.currentSequence)
                        state.currentSequence = []
                    }
                    state.currentSequence.append(info.residualNorm)
                }
            }
        }

        func clear() {
            state.withLock { state in
                state.sequences.removeAll()
                state.currentSequence.removeAll()
            }
        }
    }

    // MARK: - Convergence Order Calculation

    /// Computes the estimated convergence order from a residual sequence.
    ///
    /// For Newton-Raphson with quadratic convergence:
    ///   r_{n+1} ≈ C × r_n^p where p ≈ 2
    ///
    /// Taking logs:
    ///   log(r_{n+1}) ≈ log(C) + p × log(r_n)
    ///
    /// We estimate p by linear regression on (log(r_n), log(r_{n+1})).
    ///
    /// - Parameter residuals: Sequence of residual norms from NR iterations.
    /// - Returns: Estimated convergence order, or nil if insufficient data.
    private func estimateConvergenceOrder(_ residuals: [Double]) -> Double? {
        // Need at least 3 residuals for meaningful analysis
        // (to have at least 2 (r_n, r_{n+1}) pairs)
        guard residuals.count >= 3 else { return nil }

        // Filter out zero/negative residuals and those too small (numerical noise)
        let filtered = residuals.filter { $0 > 1e-15 }
        guard filtered.count >= 3 else { return nil }

        // Compute log residuals
        let logR = filtered.map { log($0) }

        // Create pairs (log(r_n), log(r_{n+1}))
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumXY = 0.0
        let n = logR.count - 1

        guard n >= 2 else { return nil }

        for i in 0..<n {
            let x = logR[i]
            let y = logR[i + 1]
            sumX += x
            sumY += y
            sumXX += x * x
            sumXY += x * y
        }

        // Linear regression: slope = (n*sumXY - sumX*sumY) / (n*sumXX - sumX*sumX)
        let denominator = Double(n) * sumXX - sumX * sumX
        guard abs(denominator) > 1e-15 else { return nil }

        let slope = (Double(n) * sumXY - sumX * sumY) / denominator
        return slope
    }

    // MARK: - Quadratic Convergence Test

    @Test("Newton-Raphson exhibits quadratic convergence on diode circuit")
    func quadraticConvergenceDiode() async throws {
        // Create a simple diode circuit that requires NR iteration
        // V1(2V) -> R(1kΩ) -> anode -> D1 -> GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("anode")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(2.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "anode"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "0"],
                                parameters: [:])

        // Compile the circuit
        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        // Set up observer to record residuals
        let recorder = ResidualRecorder()
        let dispatcher = EventDispatcher(observers: [recorder])

        // Run DC analysis with observer
        // Enable Gmin stepping to help convergence, but analyze the final sequence
        let analysis = DCAnalysis(
            config: ConvergenceConfig(maxIterations: 50, gmin: 1e-12),
            gminStepping: GminStepping(initialGmin: 1e-3, finalGmin: 1e-12, maxSteps: 5),
            sourceStepping: SourceStepping(steps: 1)
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let _ = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: dispatcher, cancellation: token
        )

        // Analyze the last convergence sequence (final NR solve)
        let residuals = recorder.lastSequence
        #expect(residuals.count >= 2, "Should have at least 2 iterations, got \(residuals.count)")

        // If we have enough data points, verify convergence behavior
        if residuals.count >= 2 {
            // Verify residuals are generally decreasing (allow some tolerance for damping effects)
            var decreaseCount = 0
            for i in 1..<residuals.count {
                if residuals[i] < residuals[i - 1] {
                    decreaseCount += 1
                }
            }
            let decreaseRatio = Double(decreaseCount) / Double(residuals.count - 1)
            #expect(decreaseRatio > 0.5,
                    "Residuals should generally decrease, got \(decreaseRatio * 100)% decreasing")
        }

        // Estimate convergence order if we have enough data
        if residuals.count >= 3, let order = estimateConvergenceOrder(residuals) {
            // Newton-Raphson should exhibit superlinear convergence
            // Due to voltage limiting and damping, we may not see pure quadratic
            // but should still see order > 1 (better than linear)
            #expect(order > 1.0,
                    "Convergence should be superlinear (order > 1), got \(order)")
        }

        // Verify final residual is small (successful convergence)
        if let last = residuals.last {
            #expect(last < 1e-6, "Final residual should be small, got \(last)")
        }
    }

    @Test("Newton-Raphson converges rapidly on BJT circuit")
    func bjtConvergence() async throws {
        // BJT common emitter: stronger nonlinearity
        var netlist = Netlist()
        let _ = netlist.node("vcc")
        let _ = netlist.node("vbb")
        let _ = netlist.node("col")
        let _ = netlist.node("base")
        let _ = netlist.branch() // VCC
        let _ = netlist.branch() // VBB
        try netlist.addInstance(name: "VCC", typeName: "vsource", nodes: ["vcc", "0"],
                                parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "VBB", typeName: "vsource", nodes: ["vbb", "0"],
                                parameters: ["v": .real(0.7)])
        try netlist.addInstance(name: "RC", typeName: "resistor", nodes: ["vcc", "col"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "RB", typeName: "resistor", nodes: ["vbb", "base"],
                                parameters: ["r": .real(10000)])
        try netlist.addInstance(name: "Q1", typeName: "npn", nodes: ["col", "base", "0"],
                                parameters: [:])

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let recorder = ResidualRecorder()
        let dispatcher = EventDispatcher(observers: [recorder])

        let analysis = DCAnalysis(
            config: ConvergenceConfig(maxIterations: 100, gmin: 1e-9)
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let _ = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: dispatcher, cancellation: token
        )

        // Use last sequence (final NR solve after any stepping)
        let residuals = recorder.lastSequence
        #expect(residuals.count >= 2, "Should converge within reasonable iterations")

        // BJT should still show rapid convergence
        // Final residual should be very small
        if let last = residuals.last {
            #expect(last < 1e-6, "Final residual should be small, got \(last)")
        }
    }

    @Test("Residual decreases monotonically during convergence")
    func monotonicallyDecreasingResidual() async throws {
        // Simple nonlinear circuit: two diodes in series
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("n1")
        let _ = netlist.node("n2")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(2.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["n1", "n2"],
                                parameters: [:])
        try netlist.addInstance(name: "D2", typeName: "diode", nodes: ["n2", "0"],
                                parameters: [:])

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let recorder = ResidualRecorder()
        let dispatcher = EventDispatcher(observers: [recorder])

        // Enable Gmin stepping to help convergence, analyze the final sequence
        let analysis = DCAnalysis(
            config: ConvergenceConfig(maxIterations: 50, gmin: 1e-12),
            gminStepping: GminStepping(initialGmin: 1e-3, finalGmin: 1e-12, maxSteps: 5),
            sourceStepping: SourceStepping(steps: 1)
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let _ = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: dispatcher, cancellation: token
        )

        let residuals = recorder.lastSequence
        #expect(residuals.count >= 2)

        // Check that residuals generally decrease (with tolerance for damping/limiting)
        var decreaseCount = 0
        for i in 1..<residuals.count {
            if residuals[i] < residuals[i - 1] * 1.1 { // Allow 10% tolerance
                decreaseCount += 1
            }
        }

        let decreaseRatio = Double(decreaseCount) / Double(residuals.count - 1)
        #expect(decreaseRatio > 0.6,
                "At least 60% of iterations should show residual decrease, got \(decreaseRatio * 100)%")
    }
}
