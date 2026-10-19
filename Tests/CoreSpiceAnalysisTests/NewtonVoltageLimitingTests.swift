import Testing
import Synchronization
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

@Suite("Newton simultaneous voltage limiting", .timeLimit(.minutes(1)))
struct NewtonVoltageLimitingTests {
    @Test("Grounded BJT base limits both junctions on the first iteration",
          arguments: ["npn", "pnp"], [true, false])
    func groundedBJTTerminals(_ typeName: String, _ groundedCollector: Bool) throws {
        var netlist = Netlist()
        let emitter = netlist.node("emitter")
        let collector = groundedCollector ? Node.ground : netlist.node("collector")
        try netlist.addInstance(name: "Q1", typeName: typeName,
            nodes: [groundedCollector ? "0" : "collector", "0", "emitter"],
            parameters: ["is": .real(1e-16)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let index = try #require(plan.topology.variableMap[.nodeVoltage(emitter)])
        let previous = [Double](repeating: 0, count: plan.topology.dimension)
        var raw = previous
        raw[index] = typeName == "npn" ? -100 : 100
        if !groundedCollector {
            let collectorIndex = try #require(plan.topology.variableMap[.nodeVoltage(collector)])
            raw[collectorIndex] = raw[index]
        }
        var candidate = previous, scratch = previous

        let alpha = try #require(NewtonVoltageLimiting.apply(raw: raw, previous: previous,
            candidate: &candidate, scratch: &scratch, devices: devices, firstIteration: true,
            damping: 1, maxProbes: 100, executionBudget: nil, cancellation: CancellationToken()))

        #expect(alpha < 1)
        let junctionVoltage = typeName == "npn" ? -candidate[index] : candidate[index]
        let parameters = BJTModelParameters()
        #expect(PNJunctionLimiter.limit(vNew: junctionVoltage, vOld: 0,
            vt: parameters.thermalVoltage, isat: parameters.saturationCurrent) == junctionVoltage)
        let collectorVoltage = groundedCollector ? 0
            : candidate[try #require(plan.topology.variableMap[.nodeVoltage(collector)])]
        let collectorJunction = typeName == "npn" ? -collectorVoltage : collectorVoltage
        #expect(PNJunctionLimiter.limit(vNew: collectorJunction, vOld: 0,
            vt: parameters.thermalVoltage, isat: parameters.saturationCurrent) == collectorJunction)
    }

    @Test("Grounded BJT terminals converge through the actual DC path with finite equation residuals",
          arguments: ["npn", "pnp"])
    func groundedBJTDC(_ typeName: String) async throws {
        var netlist = Netlist()
        let emitter = netlist.node("emitter")
        try netlist.addInstance(name: "Q1", typeName: typeName, nodes: ["0", "0", "emitter"],
            parameters: ["is": .real(1e-16)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["emitter", "0"],
            parameters: ["i": .real(typeName == "npn" ? 4e-10 : -4e-10)])
        let config = ConvergenceConfig(gmin: 0)
        let result = try await CircuitFactory.runDC(netlist, config: config)
        let voltage = try result.voltage(at: emitter)
        #expect(voltage.isFinite)
        #expect(typeName == "npn" ? voltage < 0 : voltage > 0)

        let (_, devices) = try CircuitFactory.compile(netlist)
        let state = SolutionState(variables: result.variables, variableMap: result.variableMap)
        var residual = 0.0
        var stamper = MatrixStamper(variableMap: result.variableMap,
            stampMatrix: { _, column, value in residual += value * result.variables[column] },
            stampRHS: { _, value in residual -= value })
        for device in devices { try device.stampDC(into: &stamper, state: state) }
        #expect(residual.isFinite && abs(residual) <= config.abstol)
    }

    @Test("Grounded BJT collector still limits BC when BE needs no correction",
          arguments: ["npn", "pnp"])
    func groundedBJTCollector(_ typeName: String) throws {
        var netlist = Netlist()
        let base = netlist.node("base"), emitter = netlist.node("emitter")
        try netlist.addInstance(name: "Q1", typeName: typeName, nodes: ["0", "base", "emitter"],
            parameters: ["is": .real(1e-16)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let baseIndex = try #require(plan.topology.variableMap[.nodeVoltage(base)])
        let emitterIndex = try #require(plan.topology.variableMap[.nodeVoltage(emitter)])
        let previous = [Double](repeating: 0, count: plan.topology.dimension)
        var raw = previous
        raw[baseIndex] = typeName == "npn" ? 100 : -100
        raw[emitterIndex] = raw[baseIndex]
        var candidate = previous, scratch = previous

        let alpha = try #require(NewtonVoltageLimiting.apply(raw: raw, previous: previous,
            candidate: &candidate, scratch: &scratch, devices: devices, firstIteration: true,
            damping: 1, maxProbes: 100, executionBudget: nil, cancellation: CancellationToken()))

        #expect(alpha < 1)
        let polarity = typeName == "npn" ? 1.0 : -1.0
        let parameters = BJTModelParameters()
        for junction in [polarity * (candidate[baseIndex] - candidate[emitterIndex]),
                         polarity * candidate[baseIndex]] {
            #expect(PNJunctionLimiter.limit(vNew: junction, vOld: 0,
                vt: parameters.thermalVoltage, isat: parameters.saturationCurrent) == junction)
        }
    }

    @Test("Grounded BJT collector and emitter retain either junction limiting rule",
          arguments: ["npn", "pnp"], [true, false])
    func groundedBJTCollectorAndEmitter(_ typeName: String, _ forwardRequiresLimiting: Bool) throws {
        let nf = forwardRequiresLimiting ? 1.0 : 100.0
        let nr = forwardRequiresLimiting ? 100.0 : 1.0
        var netlist = Netlist()
        let base = netlist.node("base")
        try netlist.addInstance(name: "Q1", typeName: typeName, nodes: ["0", "base", "0"],
            parameters: ["is": .real(1e-16), "nf": .real(nf), "nr": .real(nr)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let index = try #require(plan.topology.variableMap[.nodeVoltage(base)])
        let previous = [Double](repeating: 0, count: plan.topology.dimension)
        var raw = previous
        raw[index] = typeName == "npn" ? 1 : -1
        var candidate = previous, scratch = previous

        let alpha = try #require(NewtonVoltageLimiting.apply(raw: raw, previous: previous,
            candidate: &candidate, scratch: &scratch, devices: devices, firstIteration: true,
            damping: 1, maxProbes: 100, executionBudget: nil, cancellation: CancellationToken()))

        #expect(alpha < 1)
        let junction = typeName == "npn" ? candidate[index] : -candidate[index]
        let parameters = BJTModelParameters()
        for coefficient in [nf, nr] {
            #expect(PNJunctionLimiter.limit(vNew: junction, vOld: 0,
                vt: coefficient * parameters.thermalVoltage, isat: parameters.saturationCurrent) == junction)
        }
    }

    @Test("Shared diode terminals retain every limiter constraint independent of device order")
    func coupledDiodeTerminals() throws {
        var netlist = Netlist()
        let input = netlist.node("in")
        let n1 = netlist.node("n1"), n2 = netlist.node("n2"), n3 = netlist.node("n3")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"], parameters: ["v": .real(3)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"], parameters: ["r": .real(1000)])
        for (name, positive, negative) in [("D1", "n1", "n2"), ("D2", "n2", "n3"), ("D3", "n3", "0")] {
            try netlist.addInstance(name: name, typeName: "diode", nodes: [positive, negative], parameters: [:])
        }
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let map = plan.topology.variableMap, count = plan.topology.dimension
        var previous = [Double](repeating: 0, count: count)
        var raw = previous
        for (node, old, proposed) in [(input, 3.0, 3.0), (n1, 3.3, 3.3),
            (n2, 3.49463, 3.020436292659e12), (n3, 0.297511, 3.020436292656e12)] {
            let index = try #require(map[.nodeVoltage(node)])
            previous[index] = old; raw[index] = proposed
        }
        let diodeDevices = devices.filter { $0 is any VoltageLimitingDevice }
        var sequential = raw
        for device in diodeDevices {
            (device as? any VoltageLimitingDevice)?.limitVoltages(solution: &sequential, previousSolution: previous)
        }
        let sequentialState = SolutionState(variables: sequential, variableMap: map)
        var stamper = MatrixStamper(variableMap: map, stampMatrix: { _, _, _ in }, stampRHS: { _, _ in })
        #expect(throws: DiodeNumericalFailure.nonfiniteEvaluation) {
            for device in diodeDevices { try device.stampDC(into: &stamper, state: sequentialState) }
        }
        var expected: [Double]?
        for ordered in [diodeDevices, Array(diodeDevices.reversed())] {
            var candidate = previous, scratch = previous
            let alpha = try #require(NewtonVoltageLimiting.apply(raw: raw, previous: previous,
                candidate: &candidate, scratch: &scratch, devices: ordered, firstIteration: false,
                damping: 0.1, maxProbes: 100, executionBudget: nil, cancellation: CancellationToken()))
            #expect(alpha > 0 && alpha < 0.1)
            for device in ordered {
                scratch = candidate
                (device as? any VoltageLimitingDevice)?.limitVoltages(solution: &scratch, previousSolution: previous)
                #expect(scratch == candidate)
                try device.stampDC(into: &stamper, state: SolutionState(variables: candidate, variableMap: map))
            }
            if let expected { #expect(candidate == expected) }
            expected = candidate
        }
    }

    @Test("First-iteration eligibility and adaptive damping are retained")
    func firstIterationEligibility() throws {
        let device = ProbeDevice(first: false)
        var candidate = [0.0], scratch = candidate
        let first = try NewtonVoltageLimiting.apply(raw: [100], previous: [0], candidate: &candidate,
            scratch: &scratch, devices: [device], firstIteration: true, damping: 0.5,
            maxProbes: 100, executionBudget: nil, cancellation: CancellationToken())
        #expect(first == 0.5 && candidate == [50])
        let later = try #require(NewtonVoltageLimiting.apply(raw: [100], previous: [0], candidate: &candidate,
            scratch: &scratch, devices: [device], firstIteration: false, damping: 0.5,
            maxProbes: 100, executionBudget: nil, cancellation: CancellationToken()))
        #expect(later <= 0.01 && candidate[0] <= 1)
    }

    @Test("Probe exhaustion restores the previous point")
    func exhaustion() throws {
        var candidate = [7.0], scratch = candidate
        let alpha = try NewtonVoltageLimiting.apply(raw: [100], previous: [0], candidate: &candidate,
            scratch: &scratch, devices: [ProbeDevice()], firstIteration: false, damping: 1,
            maxProbes: 1, executionBudget: nil, cancellation: CancellationToken())
        #expect(alpha == nil && candidate == [0])
    }

    @Test("Nonfinite raw and device output fail explicitly", arguments: [false, true])
    func nonfinite(_ deviceOutput: Bool) throws {
        var candidate = [0.0], scratch = candidate
        do {
            _ = try NewtonVoltageLimiting.apply(raw: [deviceOutput ? 0.5 : .infinity], previous: [0],
                candidate: &candidate, scratch: &scratch, devices: [ProbeDevice(nonfinite: deviceOutput)],
                firstIteration: false, damping: 1, maxProbes: 100, executionBudget: nil,
                cancellation: CancellationToken(), iteration: 7)
            Issue.record("Expected nonfinite limiting failure")
        } catch AnalysisError.nonFiniteSolution(let iteration, let index, let value) {
            #expect(iteration == 7 && index == 0 && value.isInfinite)
        }
    }

    @Test("Cancellation before and during a limiter propagates", arguments: [false, true])
    func cancellation(_ during: Bool) throws {
        let token = CancellationToken()
        if !during { token.cancel() }
        var candidate = [0.0], scratch = candidate
        do {
            _ = try NewtonVoltageLimiting.apply(raw: [0.5], previous: [0], candidate: &candidate,
                scratch: &scratch, devices: [ProbeDevice(cancellation: during ? token : nil)],
                firstIteration: false, damping: 1, maxProbes: 100, executionBudget: nil, cancellation: token)
            Issue.record("Expected cancellation")
        } catch AnalysisError.cancelled {}
    }

    @Test("Every probe charges work before invoking the device")
    func workAdmission() throws {
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 10,
            maximumWorkUnits: 1000, maximumBreakpoints: 10)
        let baseline = try TransientExecutionBudget(limits: limits, dimension: 1, nonZeroCount: 1, deviceCount: 1)
        var candidate = [0.0], scratch = candidate
        _ = try NewtonVoltageLimiting.apply(raw: [0.5], previous: [0], candidate: &candidate,
            scratch: &scratch, devices: [ProbeDevice()], firstIteration: false, damping: 1,
            maxProbes: 100, executionBudget: baseline, cancellation: CancellationToken())
        let work = baseline.statistics.workUnits
        #expect(work > 0 && baseline.statistics.solveAttempts == 0 && baseline.statistics.newtonIterations == 0)
        let budget = try TransientExecutionBudget(limits: limits, dimension: 1, nonZeroCount: 1, deviceCount: 1)
        try budget.chargeWork(limits.maximumWorkUnits - work + 1)
        let calls = Calls()
        do {
            _ = try NewtonVoltageLimiting.apply(raw: [0.5], previous: [0], candidate: &candidate,
                scratch: &scratch, devices: [ProbeDevice(calls: calls)], firstIteration: false,
                damping: 1, maxProbes: 100, executionBudget: budget, cancellation: CancellationToken())
            Issue.record("Expected work quota failure before device invocation")
        } catch TransientExecutionError.limitExceeded(let resource, _, _) {
            #expect(resource == "workUnits" && calls.count.withLock { $0 } == 0)
        }
    }

    private final class Calls: Sendable {
        let count = Mutex(0)
    }

    private struct ProbeDevice: VoltageLimitingDevice {
        var first = true
        var nonfinite = false
        var cancellation: CancellationToken?
        var calls: Calls?
        var instance: Instance { Instance(name: "limiter", typeName: "test", nodes: [], parameters: [:]) }
        var limitsFirstIteration: Bool { first }
        func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
            calls?.count.withLock { $0 += 1 }
            cancellation?.cancel()
            solution[0] = nonfinite ? .infinity : min(previousSolution[0] + 1, solution[0])
        }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {}
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {}
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {}
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
    }
}
