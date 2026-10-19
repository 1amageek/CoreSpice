import Testing
import Foundation
import Synchronization
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceEvent
@testable import CoreSpiceIR

@Suite("Fixed-bias network parameters", .timeLimit(.minutes(1)))
struct NetworkParametersTests {
    private var executionLimits: TransientExecutionLimits {
        TransientExecutionLimits(maximumAcceptedSteps: 100, maximumSolveAttempts: 1_000,
            maximumNewtonIterations: 1_000, maximumSavedScalars: 100_000, maximumMatrixDimension: 100,
            maximumWorkUnits: 100_000_000, maximumBreakpoints: 100)
    }

    private func limits(bytes: Int = 10_000_000, scalars: Int = 100_000,
                        execution: TransientExecutionLimits? = nil) -> NetworkParameterLimits {
        NetworkParameterLimits(maximumPorts: 10, maximumFrequencyPoints: 100,
            maximumResultScalars: scalars, maximumTemporaryBytes: bytes, residualTolerance: 1e-10,
            executionLimits: execution ?? executionLimits)
    }

    private func addPort(_ netlist: inout Netlist, name: String, positive: String,
                         negative: String = "0", bias: Double = 0, ac: Double = 19) throws {
        let branch = netlist.branch()
        try netlist.addInstance(name: name, typeName: "vsource", nodes: [positive, negative],
            parameters: ["v": .real(bias), "ac": .real(ac), "acphase": .real(37)], ownedBranches: [branch])
    }

    private func passive(reverseFirst: Bool = false) throws -> Netlist {
        var netlist = Netlist()
        try addPort(&netlist, name: "V1", positive: reverseFirst ? "0" : "p1",
            negative: reverseFirst ? "p1" : "0", bias: reverseFirst ? -2 : 2)
        try addPort(&netlist, name: "V2", positive: "p2", bias: 3)
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["p1", "0"], parameters: ["r": .real(100)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["p2", "0"], parameters: ["r": .real(200)])
        try netlist.addInstance(name: "RB", typeName: "resistor", nodes: ["p1", "p2"], parameters: ["r": .real(50)])
        return netlist
    }

    private func ports(_ count: Int = 2) throws -> [NetworkPort] {
        try (1...count).map { try NetworkPort(voltageSourceName: "V\($0)", referenceImpedance: $0 == 1 ? 25 : 100) }
    }

    private func run(_ netlist: Netlist, frequencies: [Double] = [1, 1_000],
                     selectedPorts: [NetworkPort]? = nil, policy: NetworkParameterLimits? = nil,
                     token: CancellationToken = CancellationToken(), observer: EventDispatcher? = nil) async throws -> NetworkParameterResult {
        let (plan, devices) = try CircuitFactory.compile(netlist)
        return try await NetworkParameterAnalysis(frequencies: frequencies, ports: selectedPorts ?? ports(),
            limits: policy ?? limits()).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: observer, cancellation: token)
    }

    private func expectClose(_ actual: ComplexPair, _ expected: ComplexPair, tolerance: Double = 1e-11,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((actual - expected).magnitude <= tolerance * max(1, expected.magnitude), sourceLocation: sourceLocation)
    }

    @Test("Analytic passive two-port, unequal reference normalization, reciprocity and unchanged DC")
    func passiveTwoPort() async throws {
        let result = try await run(passive())
        #expect(result.points.count == 2)
        for point in result.points {
            let expected = [0.03, -0.02, -0.02, 0.025]
            for index in expected.indices { expectClose(point.y.values[index], ComplexPair(real: expected[index])) }
            // Independent scalar 2x2 formula with a=.75, b=c=-1, d=2.5.
            let denominator = 1.75 * 3.5 - 1.0
            let s = [(0.25 * 3.5 + 1) / denominator, 2 / denominator,
                     2 / denominator, (1.75 * -1.5 + 1) / denominator]
            for index in s.indices { expectClose(point.s.values[index], ComplexPair(real: s[index])) }
            expectClose(point.s.values[1], point.s.values[2])
            guard case .defined(let z) = point.z else { Issue.record("Expected finite impedance"); return }
            let determinant = 0.03 * 0.025 - 0.02 * 0.02
            for (index, value) in [0.025, 0.02, 0.02, 0.03].enumerated() {
                expectClose(z.values[index], ComplexPair(real: value / determinant))
            }
            #expect(point.maximumBackwardResidual <= 1e-10)
            #expect(point.stability?.satisfiesRollettInequalities == true)
        }
        let (plan, _) = try CircuitFactory.compile(passive())
        let p1 = try #require(plan.ir.nodeNames.first(where: { $0.value == "p1" })?.key)
        let p2 = try #require(plan.ir.nodeNames.first(where: { $0.value == "p2" })?.key)
        let bias1 = try result.operatingPoint.voltage(at: p1)
        let bias2 = try result.operatingPoint.voltage(at: p2)
        #expect(abs(bias1 - 2) < 1e-10)
        #expect(abs(bias2 - 3) < 1e-10)
    }

    @Test("Reversing one source reverses both its voltage and inward-current orientation")
    func portOrientation() async throws {
        let result = try await run(passive(reverseFirst: true), frequencies: [1_000])
        expectClose(result.points[0].y.values[0], ComplexPair(real: 0.03))
        expectClose(result.points[0].y.values[1], ComplexPair(real: 0.02))
        expectClose(result.points[0].y.values[2], ComplexPair(real: 0.02))
        expectClose(result.points[0].y.values[3], ComplexPair(real: 0.025))
    }

    @Test("RC one-port retains complex susceptance and ignores original AC excitations")
    func rcOnePort() async throws {
        var netlist = Netlist()
        try addPort(&netlist, name: "V1", positive: "p", bias: 4, ac: 123)
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["p", "0"], parameters: ["r": .real(50)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["p", "0"], parameters: ["c": .real(1e-6)])
        try netlist.addInstance(name: "I", typeName: "isource", nodes: ["p", "0"],
            parameters: ["i": .real(0.01), "ac": .real(17)])
        let selected = [try NetworkPort(voltageSourceName: "V1", referenceImpedance: 50)]
        let result = try await run(netlist, frequencies: [100], selectedPorts: selected)
        let expectedY = ComplexPair(real: 0.02, imag: 2 * .pi * 100 * 1e-6)
        expectClose(result.points[0].y.values[0], expectedY)
        let a = expectedY * ComplexPair(real: 50)
        expectClose(result.points[0].s.values[0], (.one - a) / (.one + a))
        guard case .defined(let z) = result.points[0].z else { Issue.record("Expected RC Z"); return }
        expectClose(z.values[0], .one / expectedY)
        #expect(result.points[0].stability == nil)
    }

    @Test("Controlled-source two-port is nonreciprocal and unilateral K is explicitly undefined")
    func controlledTwoPort() async throws {
        var netlist = Netlist()
        try addPort(&netlist, name: "V1", positive: "p1")
        try addPort(&netlist, name: "V2", positive: "p2")
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["p1", "0"], parameters: ["r": .real(100)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["p2", "0"], parameters: ["r": .real(200)])
        try netlist.addInstance(name: "G", typeName: "vccs", nodes: ["p2", "0", "p1", "0"],
            parameters: ["g": .real(0.04)])
        let result = try await run(netlist, frequencies: [1_000])
        let point = result.points[0]
        for (index, value) in [0.01, 0, 0.04, 0.005].enumerated() {
            expectClose(point.y.values[index], ComplexPair(real: value))
        }
        expectClose(point.s.values[1], .zero)
        #expect(point.s.values[1] == .zero)
        expectClose(point.s.values[2], ComplexPair(real: -4 / (1.25 * 1.5)))
        #expect(point.stability?.rollettK == .undefined(.zeroDenominator))
        #expect(point.stability?.satisfiesRollettInequalities == nil)
    }

    @Test("Same-factor correction repairs a homogeneous row without changing its backward-residual gate")
    func homogeneousRowRefinement() throws {
        let structure = try SparseStructure(dimension: 2, rowPointers: [0, 2, 4], columnIndices: [0, 1, 0, 1])
        var matrix = ComplexSparseMatrix(structure: structure)
        for (index, value) in [1.25, 0, 2, 1.5].enumerated() {
            matrix.addValueDirect(at: index, value: ComplexPair(real: value))
        }
        for admittedAttempts in [1, 2] {
            var policy = executionLimits; policy.maximumSolveAttempts = admittedAttempts
            let budget = try TransientExecutionBudget(limits: policy, dimension: 2, nonZeroCount: 4, deviceCount: 0)
            let control = NetworkParameterControl(maximumBytes: 100_000, budget: budget,
                cancellation: CancellationToken(), upstream: nil)
            try budget.beginLinearSolve(complex: true)
            var solver = ComplexSparseLUSolver(useAMDOrdering: false)
            try solver.configureExecution(control)
            try solver.factorize(matrix: matrix)
            var solution = [ComplexPair](repeating: .zero, count: 2)
            var residual = solution, correction = solution
            do {
                let quality = try NetworkParameterTransforms.solveChecked(matrix: matrix,
                    rhs: [.zero, ComplexPair(real: 0.5)], solver: &solver, solution: &solution,
                    residualBuffer: &residual, correctionBuffer: &correction,
                    tolerance: 1e-10, control: control)
                #expect(admittedAttempts == 2)
                #expect(solution[0] == .zero)
                expectClose(solution[1], ComplexPair(real: 1.0 / 3.0))
                #expect(quality <= 1e-10)
                #expect(solver.statistics.numericFactorizations == 1)
                #expect(budget.statistics.solveAttempts == 2)
            } catch TransientExecutionError.limitExceeded(let resource, _, _) {
                #expect(admittedAttempts == 1)
                #expect(resource == "solveAttempts")
                #expect(budget.statistics.solveAttempts == 1)
            }
        }
    }

    @Test("Open port publishes finite Y/S and an explicitly undefined Z")
    func openPort() async throws {
        var netlist = Netlist()
        try addPort(&netlist, name: "V1", positive: "open")
        let result = try await run(netlist, frequencies: [1], selectedPorts: ports(1))
        expectClose(result.points[0].y.values[0], .zero)
        expectClose(result.points[0].s.values[0], .one)
        #expect(result.points[0].z == .undefined(.singularAdmittance))
    }

    @Test("Singular S transform is refused rather than returning infinity")
    func singularScattering() async throws {
        var netlist = Netlist()
        try addPort(&netlist, name: "V1", positive: "p")
        try netlist.addInstance(name: "G", typeName: "vccs", nodes: ["p", "0", "p", "0"],
            parameters: ["g": .real(-0.02)])
        let selected = [try NetworkPort(voltageSourceName: "V1", referenceImpedance: 50)]
        do { _ = try await run(netlist, frequencies: [1], selectedPorts: selected); Issue.record("Expected singular S refusal") }
        catch NetworkParameterError.singularScatteringTransform {}
    }

    @Test("Invalid frequency plans, missing/duplicate/wrong/unowned ports and dependent voltage constraints refuse")
    func invalidRequests() async throws {
        let netlist = try passive()
        for frequencies in [[], [0], [-1], [.nan], [.infinity], [1, 1], [2, 1], [Double.greatestFiniteMagnitude]] {
            do { _ = try await run(netlist, frequencies: frequencies); Issue.record("Expected invalid frequency refusal") }
            catch let error as NetworkParameterError { guard case .invalidConfiguration = error else { throw error } }
        }
        for selected in [[], [try NetworkPort(voltageSourceName: "missing", referenceImpedance: 50)],
                         [try NetworkPort(voltageSourceName: "R1", referenceImpedance: 50)],
                         [try NetworkPort(voltageSourceName: "V1", referenceImpedance: 50),
                          try NetworkPort(voltageSourceName: "v1", referenceImpedance: 50)]] {
            do { _ = try await run(netlist, frequencies: [1], selectedPorts: selected); Issue.record("Expected invalid port refusal") }
            catch is NetworkParameterError {}
        }
        var unowned = Netlist()
        _ = unowned.branch()
        try unowned.addInstance(name: "V1", typeName: "vsource", nodes: ["p", "0"], parameters: ["v": .real(0)])
        do { _ = try await run(unowned, frequencies: [1], selectedPorts: ports(1)); Issue.record("Expected unowned refusal") }
        catch NetworkParameterError.invalidPort {}
        var dependent = Netlist()
        try addPort(&dependent, name: "V1", positive: "a")
        try addPort(&dependent, name: "V2", positive: "b")
        try addPort(&dependent, name: "V3", positive: "a", negative: "b")
        do { _ = try await run(dependent, frequencies: [1], selectedPorts: ports(3)); Issue.record("Expected dependent-port refusal") }
        catch NetworkParameterError.dependentPorts {}
        var shorted = Netlist()
        try addPort(&shorted, name: "V1", positive: "0")
        do { _ = try await run(shorted, frequencies: [1], selectedPorts: ports(1)); Issue.record("Expected shorted source refusal") }
        catch NetworkParameterError.invalidPort {}
    }

    @Test("Finite matrix and reference validation; sampled algebraic K/mu formulas")
    func checkedValuesAndMetrics() throws {
        for reference in [0, -1, .nan, .infinity] {
            #expect(throws: NetworkParameterError.self) { try NetworkPort(voltageSourceName: "V1", referenceImpedance: reference) }
        }
        #expect(throws: NetworkParameterError.self) { try NetworkParameterMatrix(portCount: 2, values: [.zero]) }
        #expect(throws: NetworkParameterError.self) { try NetworkParameterMatrix(portCount: Int.max, values: []) }
        #expect(throws: NetworkParameterError.self) { try NetworkParameterMatrix(portCount: 1, values: [ComplexPair(real: .nan)]) }
        let s = try NetworkParameterMatrix(portCount: 2,
            values: [ComplexPair(real: 0.1), ComplexPair(real: 0.2), ComplexPair(real: 0.3), ComplexPair(real: 0.4)])
        let metric = try TwoPortStability(scattering: s)
        expectClose(metric.delta, ComplexPair(real: -0.02))
        if case .defined(let k) = metric.rollettK { #expect(abs(k - (1 - 0.01 - 0.16 + 0.0004) / 0.12) < 1e-12) }
        else { Issue.record("Expected defined K") }
        if case .defined(let mu) = metric.mu { #expect(abs(mu - 0.99 / 0.462) < 1e-12) }
        else { Issue.record("Expected defined mu") }
        if case .defined(let reverse) = metric.reverseMu { #expect(abs(reverse - 0.84 / 0.168) < 1e-12) }
        else { Issue.record("Expected defined reverse mu") }
        #expect(metric.satisfiesRollettInequalities == true)
        #expect(throws: NetworkParameterError.self) { try s.value(row: 2, column: 0) }
    }

    @Test("Caller scalar/temporary/work/solve ceilings and cancellation are propagated")
    func resourceRefusals() async throws {
        let netlist = try passive()
        do { _ = try await run(netlist, policy: limits(scalars: 1)); Issue.record("Expected scalar limit") }
        catch TransientExecutionError.limitExceeded {}
        do { _ = try await run(netlist, policy: limits(bytes: 1)); Issue.record("Expected temporary limit") }
        catch NetworkParameterError.temporaryStorageExceeded {}
        var work = executionLimits; work.maximumWorkUnits = 1
        do { _ = try await run(netlist, policy: limits(execution: work)); Issue.record("Expected work limit") }
        catch TransientExecutionError.limitExceeded {}
        var solve = executionLimits; solve.maximumSolveAttempts = 1
        do { _ = try await run(netlist, policy: limits(execution: solve)); Issue.record("Expected solve limit") }
        catch TransientExecutionError.limitExceeded {}
        let cancelled = CancellationToken(); cancelled.cancel()
        do { _ = try await run(netlist, token: cancelled); Issue.record("Expected cancellation") }
        catch AnalysisError.cancelled {}
    }

    @Test("A thermal row cannot serve as an electrical network port")
    func thermalPortRefusal() async throws {
        let (plan, devices) = try CircuitFactory.compile(passive())
        let p1 = try #require(plan.ir.nodeNames.first(where: { $0.value == "p1" })?.key)
        let thermalIndex = try #require(plan.topology.variableMap[.nodeVoltage(p1)])
        let potentialIndices = Set(plan.topology.variableMap.compactMap { variable, index -> Int? in
            if case .nodeVoltage = variable { return index }; return nil
        })
        var rows = [DCEquationRowPolicy]()
        for row in 0..<plan.topology.dimension {
            let kind: DCEquationKind = row == thermalIndex ? .thermalPotential
                : (potentialIndices.contains(row) ? .electricalPotential : .electricalFlow)
            rows.append(try DCEquationRowPolicy(kind: kind, variableAbsoluteTolerance: 1e-10,
                equationAbsoluteTolerance: 1e-10))
        }
        let policy = try DCEquationPolicy(rows: rows)
        let analysis = NetworkParameterAnalysis(frequencies: [1], ports: try ports(), limits: limits(), equationPolicy: policy)
        do {
            _ = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
            Issue.record("Expected electrical endpoint refusal")
        } catch AnalysisError.invalidConfiguration {}
    }

    @Test("Local scratch leases refund after upstream refusal and preserve cumulative budget")
    func scratchRefundAndBudget() throws {
        let budget = try TransientExecutionBudget(limits: executionLimits, dimension: 2, nonZeroCount: 4, deviceCount: 1)
        let storage = RefusingStorage()
        let control = NetworkParameterControl(maximumBytes: 100, budget: budget,
            cancellation: CancellationToken(), upstream: storage)
        do { _ = try control.reserveStorage(byteCount: 10); Issue.record("Expected upstream refusal") }
        catch RefusingStorage.Refusal.refused {}
        #expect(control.liveBytes == 0)
        let ordinary = NetworkParameterControl(maximumBytes: 100, budget: budget,
            cancellation: CancellationToken(), upstream: nil)
        do {
            let lease = try ordinary.reserveStorage(byteCount: 80)
            #expect(ordinary.liveBytes == 80)
            #expect(throws: NetworkParameterError.self) { try ordinary.reserveStorage(byteCount: 30) }
            try ordinary.checkpoint(workUnits: 7)
            withExtendedLifetime(lease) {}
        }
        #expect(ordinary.liveBytes == 0)
        #expect(budget.statistics.workUnits == 7)
    }

    @Test("Actual AC stamp failures and in-flight cancellation refund all temporary reservations")
    func actualStampFailureAndCancellation() async throws {
        for nonfinite in [false, true] {
            let (plan, bound) = try CircuitFactory.compile(passive())
            let token = CancellationToken()
            let probe = StampProbe(base: bound[2], cancellation: nonfinite ? nil : token, nonfinite: nonfinite)
            var devices = bound; devices[2] = probe
            let storage = TrackingStorage()
            let observer = TerminalObserver()
            var analysis = NetworkParameterAnalysis(frequencies: [1, 2], ports: try ports(), limits: limits())
            analysis.resultStorage = storage
            do {
                _ = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(),
                    observer: EventDispatcher(observers: [observer]), cancellation: token)
                Issue.record("Expected actual stamp failure or in-flight cancellation")
            } catch AnalysisError.cancelled {
                #expect(!nonfinite)
            } catch SparseSolverError.nonFiniteMatrixValue {
                #expect(nonfinite)
            }
            #expect(probe.stamps == 1)
            #expect(storage.liveBytes == 0)
            #expect(observer.status == (nonfinite ? .failed : .cancelled))
        }
    }

    @Test("Original-matrix residual gate rejects a finite incorrect solution")
    func originalResidualRefusal() throws {
        let structure = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0])
        var matrix = ComplexSparseMatrix(structure: structure)
        matrix.addValueDirect(at: 0, value: ComplexPair(real: 2))
        let budget = try TransientExecutionBudget(limits: executionLimits, dimension: 1, nonZeroCount: 1, deviceCount: 0)
        let control = NetworkParameterControl(maximumBytes: 100, budget: budget,
            cancellation: CancellationToken(), upstream: nil)
        #expect(throws: NetworkParameterError.self) {
            try NetworkParameterTransforms.residual(matrix: matrix, rhs: [.one], solution: [.one],
                tolerance: 1e-10, control: control)
        }
    }

    @Test("AC matrix stamps run once per frequency across multiple port RHS")
    func sharedStampAndBudget() async throws {
        let (plan, bound) = try CircuitFactory.compile(passive())
        let probe = StampProbe(base: bound[2], cancellation: nil, nonfinite: false)
        var devices = bound; devices[2] = probe
        let budget = try TransientExecutionBudget(limits: executionLimits, dimension: plan.topology.dimension,
            nonZeroCount: plan.matrixStructure.nonZeroCount, deviceCount: devices.count)
        try budget.chargeWork(11)
        var analysis = NetworkParameterAnalysis(frequencies: [1, 2, 3], ports: try ports(), limits: limits())
        analysis.executionBudget = budget
        let result = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken())
        #expect(result.points.count == 3)
        #expect(probe.stamps == 3)
        #expect(budget.statistics.newtonIterations > 0)
        #expect(budget.statistics.solveAttempts >= 18)
        #expect(budget.statistics.workUnits > 11)
    }

    @Test("Saved network math exactly replays and shares cumulative work without source execution")
    func savedPointReplay() async throws {
        let result = try await run(passive(), frequencies: [1])
        let point = result.points[0]
        let resources = try AnalysisExecutionResources(limits: executionLimits)
        for _ in 0..<2 {
            let before = resources.usage.workUnits
            let restored = try NetworkParameterPoint.validatingSaved(frequency: point.frequency,
                y: point.y, s: point.s, z: point.z, stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(), resources: resources, cancellation: CancellationToken())
            #expect(restored.frequency.bitPattern == point.frequency.bitPattern)
            for index in point.s.values.indices {
                #expect(restored.s.values[index].real.bitPattern == point.s.values[index].real.bitPattern)
                #expect(restored.s.values[index].imag.bitPattern == point.s.values[index].imag.bitPattern)
            }
            #expect(resources.usage.workUnits > before)
        }
        #expect(resources.usage.newtonIterations == 0)
        #expect(resources.usage.solveAttempts == 8)
    }

    @Test("Saved finite Z mutations, availability forgery, S/ref changes and metric forgery are refused")
    func savedPointTampering() async throws {
        let result = try await run(passive(), frequencies: [1])
        let point = result.points[0]
        guard case .defined(let z) = point.z else { Issue.record("Expected finite Z"); return }
        var alteredZ = z.values; alteredZ[0].real = alteredZ[0].real.nextUp
        let zMutation = try NetworkParameterMatrix(portCount: 2, values: alteredZ)
        let resources = try AnalysisExecutionResources(limits: executionLimits)
        for savedZ in [NetworkImpedanceParameters.defined(zMutation), .undefined(.singularAdmittance)] {
            #expect(throws: NetworkParameterError.self) {
                try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                    s: point.s, z: savedZ, stability: point.stability,
                    maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                    limits: limits(), resources: resources, cancellation: CancellationToken())
            }
        }
        var alteredS = point.s.values; alteredS[0].real = alteredS[0].real.nextUp
        let sMutation = try NetworkParameterMatrix(portCount: 2, values: alteredS)
        #expect(throws: NetworkParameterError.self) {
            try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: sMutation, z: point.z, stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(), resources: resources, cancellation: CancellationToken())
        }
        let references = [try NetworkPort(voltageSourceName: "V1", referenceImpedance: 26), result.ports[1]]
        #expect(throws: NetworkParameterError.self) {
            try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: point.s, z: point.z, stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: references,
                limits: limits(), resources: resources, cancellation: CancellationToken())
        }
        let metric = try #require(point.stability)
        let forged = try TwoPortStability(savedDelta: metric.delta, rollettK: .undefined(.zeroDenominator),
            mu: metric.mu, reverseMu: metric.reverseMu, satisfiesRollettInequalities: nil)
        for savedMetric in [Optional<TwoPortStability>.none, forged] {
            #expect(throws: NetworkParameterError.self) {
                try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                    s: point.s, z: point.z, stability: savedMetric,
                    maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                    limits: limits(), resources: resources, cancellation: CancellationToken())
            }
        }
    }

    @Test("True singular saved Z and non-two-port not-applicable stability survive replay")
    func savedSingularPoint() async throws {
        var netlist = Netlist()
        try addPort(&netlist, name: "V1", positive: "open")
        let result = try await run(netlist, frequencies: [1], selectedPorts: ports(1))
        let point = result.points[0]
        let resources = try AnalysisExecutionResources(limits: executionLimits)
        let restored = try NetworkParameterPoint.validatingSaved(frequency: point.frequency,
            y: point.y, s: point.s, z: point.z, stability: nil,
            maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
            limits: limits(), resources: resources, cancellation: CancellationToken())
        #expect(restored.z == .undefined(.singularAdmittance))
        #expect(restored.stability == nil)
        let fakeZ = NetworkImpedanceParameters.defined(try NetworkParameterMatrix(portCount: 1, values: [.zero]))
        #expect(throws: NetworkParameterError.self) {
            try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: point.s, z: fakeZ, stability: nil,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(), resources: resources, cancellation: CancellationToken())
        }
    }

    @Test("Saved-point residual/frequency class, cancellation, scratch and work refusal remain explicit")
    func savedPointAdmission() async throws {
        let result = try await run(passive(), frequencies: [1])
        let point = result.points[0]
        let resources = try AnalysisExecutionResources(limits: executionLimits)
        for residual in [-1, Double.nan, Double.infinity, 1.0] {
            #expect(throws: NetworkParameterError.self) {
                try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                    s: point.s, z: point.z, stability: point.stability,
                    maximumBackwardResidual: residual, ports: result.ports,
                    limits: limits(), resources: resources, cancellation: CancellationToken())
            }
        }
        for frequency in [0, Double.nan, Double.infinity] {
            #expect(throws: NetworkParameterError.self) {
                try NetworkParameterPoint.validatingSaved(frequency: frequency, y: point.y,
                    s: point.s, z: point.z, stability: point.stability,
                    maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                    limits: limits(), resources: resources, cancellation: CancellationToken())
            }
        }
        let budget = try resources.budget(dimension: 2, nonZeroCount: 4, deviceCount: 0)
        let storage = TrackingStorage()
        #expect(throws: NetworkParameterError.self) {
            try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: point.s, z: .undefined(.singularAdmittance), stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(), budget: budget, storage: storage, cancellation: CancellationToken())
        }
        #expect(storage.liveBytes == 0)
        let token = CancellationToken(); token.cancel()
        do {
            _ = try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: point.s, z: point.z, stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(), resources: resources, cancellation: token)
            Issue.record("Cancelled saved-point validation published a result")
        } catch AnalysisError.cancelled {}
        #expect(throws: NetworkParameterError.self) {
            try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: point.s, z: point.z, stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(bytes: 1), resources: resources, cancellation: CancellationToken())
        }
        var work = executionLimits; work.maximumWorkUnits = 1
        let scarce = try AnalysisExecutionResources(limits: work)
        #expect(throws: TransientExecutionError.self) {
            try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                s: point.s, z: point.z, stability: point.stability,
                maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                limits: limits(execution: work), resources: scarce, cancellation: CancellationToken())
        }
    }

    @Test("Saved replay refuses mismatched execution policies before numerical work")
    func savedPointPolicyMismatch() async throws {
        let result = try await run(passive(), frequencies: [1])
        let point = result.points[0]
        let resources = try AnalysisExecutionResources(limits: executionLimits)
        let budget = try resources.budget(dimension: 2, nonZeroCount: 4, deviceCount: 0)
        let before = resources.usage
        for restrictDimension in [true, false] {
            var declared = executionLimits
            if restrictDimension { declared.maximumMatrixDimension = 1 }
            else { declared.maximumWorkUnits = 1 }
            let policy = limits(execution: declared)
            #expect(throws: NetworkParameterError.self) {
                try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                    s: point.s, z: point.z, stability: point.stability,
                    maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                    limits: policy, resources: resources, cancellation: CancellationToken())
            }
            #expect(throws: NetworkParameterError.self) {
                try NetworkParameterPoint.validatingSaved(frequency: point.frequency, y: point.y,
                    s: point.s, z: point.z, stability: point.stability,
                    maximumBackwardResidual: point.maximumBackwardResidual, ports: result.ports,
                    limits: policy, budget: budget, storage: nil, cancellation: CancellationToken())
            }
        }
        #expect(resources.usage == before)
    }

    private final class StampProbe: BoundDevice, Sendable {
        let base: any BoundDevice
        let cancellation: CancellationToken?
        let nonfinite: Bool
        private let count = Mutex(0)
        var instance: Instance { base.instance }
        var stamps: Int { count.withLock { $0 } }
        init(base: any BoundDevice, cancellation: CancellationToken?, nonfinite: Bool) {
            self.base = base; self.cancellation = cancellation; self.nonfinite = nonfinite
        }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
            try base.stampDC(into: &stamper, state: state)
        }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
            count.withLock { $0 += 1 }
            try base.stampAC(into: &stamper, state: state, omega: omega)
            if nonfinite { stamper.stampMatrix(0, 0, .nan, 0) }
            cancellation?.cancel()
        }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
            try base.stampTransient(into: &stamper, state: state, integration: integration)
        }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
            base.checkConvergence(state: state, previousState: previousState)
        }
    }

    private final class TerminalObserver: AnalysisObserver, Sendable {
        private let value = Mutex<AnalysisStatus?>(nil)
        var status: AnalysisStatus? { value.withLock { $0 } }
        func onEvent(_ event: AnalysisEvent) {
            if case .analysisFinished(let info) = event, info.type == .networkParameters {
                value.withLock { $0 = info.status }
            }
        }
    }

    private final class TrackingStorage: AnalysisResultStorageAccounting, Sendable {
        private let live = Mutex(0)
        var liveBytes: Int { live.withLock { $0 } }
        func reserveResultScalars(_ capacity: Int) throws {}
        func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
            let bytes = try #require(Int(exactly: byteCount))
            live.withLock { $0 += bytes }
            return Reservation(storage: self, count: bytes)
        }
        private final class Reservation: Sendable {
            let storage: TrackingStorage
            let count: Int
            init(storage: TrackingStorage, count: Int) { self.storage = storage; self.count = count }
            deinit { storage.live.withLock { $0 -= count } }
        }
    }

    private final class RefusingStorage: AnalysisResultStorageAccounting, Sendable {
        enum Refusal: Error { case refused }
        func reserveResultScalars(_ capacity: Int) throws {}
        func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable { throw Refusal.refused }
    }
}
