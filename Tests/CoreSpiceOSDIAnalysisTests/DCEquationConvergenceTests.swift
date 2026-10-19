import Testing
import Synchronization
@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

@Suite("DC unit-aware equation convergence", .timeLimit(.minutes(1)))
struct DCEquationConvergenceTests {
    private let voltage = Node(id: 1)
    private let thermal = Node(id: 2)
    private let flow = Branch(id: 0)

    private func row(_ kind: DCEquationKind, variable: Double = 1e-10,
        equation: Double = 1e-10) throws -> DCEquationRowPolicy {
        try .init(kind: kind, variableAbsoluteTolerance: variable,
            equationAbsoluteTolerance: equation)
    }

    @Test("Real SparseLU adds gmin only to V/A rows")
    func electricalOnlyGmin() async throws {
        let map: [MNAVariable: Int] = [.nodeVoltage(voltage): 0, .branchCurrent(flow): 1,
            .nodeVoltage(thermal): 2]
        let policy = try DCEquationPolicy(rows: [row(.electricalPotential), row(.electricalFlow),
            row(.thermalPotential)])
        var matrix = SparseMatrix(structure: try .fromTriplets(dimension: 3,
            entries: [(0, 0), (1, 1), (2, 2)]))
        var rhs = [Double](repeating: 0, count: 3)
        var solver: any LinearSolver = SparseLUSolver()
        let result = try await NewtonRaphsonSolver(config: .init(reltol: 0, maxIterations: 3, gmin: 0.5),
            equationPolicy: policy).solve(initialGuess: [0, 0, 0], matrix: &matrix, rhs: &rhs,
            devices: [], variableMap: map, solver: &solver, stampFunction: { stamper, _ in
                for index in 0..<3 {
                    stamper.stampMatrix(index, index, 1)
                    stamper.stampRHS(index, 3)
                }
            }, observer: nil, analysisID: AnalysisID(), cancellation: CancellationToken())
        #expect(result.solution == [2, 3, 3])
        #expect(result.iterations == 2)
        #expect(matrix.values == [1.5, 1, 1])
    }

    @Test("Thermal K update uses caller K tolerance, not legacy voltage tolerance")
    func thermalUpdateTolerance() async throws {
        for tolerance in [3.0, 1e-10] {
            let policy = try DCEquationPolicy(rows: [row(.electricalPotential),
                row(.thermalPotential, variable: tolerance)])
            var matrix = SparseMatrix(structure: try .fromTriplets(dimension: 2,
                entries: [(0, 0), (1, 1)]))
            var rhs = [0.0, 0.0]
            var solver: any LinearSolver = SparseLUSolver()
            do {
                let result = try await NewtonRaphsonSolver(config: .init(reltol: 0, maxIterations: 1, gmin: 0),
                    equationPolicy: policy).solve(initialGuess: [0, 0], matrix: &matrix, rhs: &rhs,
                    devices: [], variableMap: [.nodeVoltage(voltage): 0, .nodeVoltage(thermal): 1],
                    solver: &solver, stampFunction: { stamper, _ in
                        stamper.stampMatrix(0, 0, 1); stamper.stampMatrix(1, 1, 1)
                        stamper.stampRHS(1, 2)
                    }, observer: nil, analysisID: AnalysisID(), cancellation: CancellationToken())
                #expect(tolerance == 3)
                #expect(result.solution == [0, 2])
            } catch AnalysisError.convergenceFailure {
                #expect(tolerance == 1e-10)
            }
        }
    }

    @Test("W equation limit is absolute even with a large linearized RHS")
    func equationToleranceHasNoRHSInflation() async throws {
        for explicit in [false, true] {
            let policy = try explicit ? DCEquationPolicy(rows: [row(.thermalPotential, equation: 0.1)]) : nil
            var matrix = SparseMatrix(structure: try .fromTriplets(dimension: 1, entries: [(0, 0)]))
            var rhs = [0.0]
            var solver: any LinearSolver = InaccurateSolver()
            do {
                _ = try await NewtonRaphsonSolver(config: .init(maxIterations: 1, gmin: 0),
                    equationPolicy: policy).solve(initialGuess: [100_000_001], matrix: &matrix,
                    rhs: &rhs, devices: [], variableMap: [.nodeVoltage(thermal): 0], solver: &solver,
                    stampFunction: { stamper, _ in
                        stamper.stampMatrix(0, 0, 1); stamper.stampRHS(0, 100_000_000)
                    }, observer: nil, analysisID: AnalysisID(), cancellation: CancellationToken())
                #expect(!explicit)
            } catch AnalysisError.convergenceFailure {
                #expect(explicit)
            }
        }
    }

    @Test("Invalid tolerances, dimensions, ranges and variable natures fail before stamping")
    func invalidPolicyAdmission() async throws {
        for value in [0, -1, Double.nan, Double.infinity] {
            #expect(throws: DCEquationPolicyError.self) {
                try row(.thermalPotential, variable: value)
            }
            #expect(throws: DCEquationPolicyError.self) {
                try row(.electricalFlow, equation: value)
            }
        }
        #expect(throws: DCEquationPolicyError.self) { try DCEquationPolicy(rows: []) }
        let policy = try DCEquationPolicy(rows: [row(.electricalPotential)])
        let invalidMaps: [[MNAVariable: Int]] = [[:], [.nodeVoltage(voltage): -1],
            [.nodeVoltage(voltage): 1], [.branchCurrent(flow): 0],
            [.nodeVoltage(voltage): 0, .nodeVoltage(thermal): 0]]
        for map in invalidMaps {
            var matrix = SparseMatrix(structure: try .fromTriplets(dimension: 1, entries: [(0, 0)]))
            var rhs = [0.0]
            var solver: any LinearSolver = SparseLUSolver()
            await #expect(throws: DCEquationPolicyError.self) {
                _ = try await NewtonRaphsonSolver(equationPolicy: policy).solve(initialGuess: [0],
                    matrix: &matrix, rhs: &rhs, devices: [], variableMap: map, solver: &solver,
                    stampFunction: { _, _ in Issue.record("Invalid policy must fail before stamping") },
                    observer: nil, analysisID: AnalysisID(), cancellation: CancellationToken())
            }
        }
        #expect(throws: DCEquationPolicyError.self) {
            try policy.validate(dimension: 2, variableMap: [:], config: .init())
        }
        for config in [ConvergenceConfig(reltol: .nan), .init(reltol: -1), .init(gmin: .infinity),
            .init(maxIterations: 0), .init(minDamping: 0)] {
            #expect(throws: AnalysisError.self) {
                try policy.validate(dimension: 1, variableMap: [.nodeVoltage(voltage): 0], config: config)
            }
        }
    }

    @Test("Explicit profile preserves singular and cancelled failures")
    func singularAndCancelled() async throws {
        let policy = try DCEquationPolicy(rows: [row(.thermalPotential)])
        for cancelled in [false, true] {
            var matrix = SparseMatrix(structure: try .fromTriplets(dimension: 1, entries: [(0, 0)]))
            var rhs = [0.0]
            var solver: any LinearSolver = SparseLUSolver()
            let token = CancellationToken()
            if cancelled { token.cancel() }
            do {
                _ = try await NewtonRaphsonSolver(config: .init(gmin: 1), equationPolicy: policy).solve(
                    initialGuess: [0], matrix: &matrix, rhs: &rhs, devices: [],
                    variableMap: [.nodeVoltage(thermal): 0], solver: &solver,
                    stampFunction: { stamper, _ in stamper.stampRHS(0, 1) }, observer: nil,
                    analysisID: AnalysisID(), cancellation: token)
                Issue.record("Thermal singularity cannot be rescued by electrical gmin")
            } catch AnalysisError.singularMatrix { #expect(!cancelled) }
              catch AnalysisError.cancelled { #expect(cancelled) }
        }
    }

    @Test("Gmin recovery forwards K/W policy to every intermediate and final solve")
    func gminRecoveryForwardsPolicy() async throws {
        let instance = Instance(name: "balance", typeName: "test", nodes: [voltage, thermal], parameters: [:])
        let ir = CircuitIR(nodes: [.ground, voltage, thermal], branches: [], instances: [instance])
        let plan = try StandardCompiler().compile(ir: ir)
        let gate = RecoveryGate()
        let device = RecoveryDevice(instance: instance, voltage: voltage, thermal: thermal,
            intermediateVoltage: 2.0 / 3.0, stampsVoltage: true, gate: gate)
        let policy = try DCEquationPolicy(rows: [row(.electricalPotential), row(.thermalPotential)])
        let result = try await DCAnalysis(config: .init(reltol: 0, maxIterations: 2, gmin: 0),
            gminStepping: .init(initialGmin: 2, finalGmin: 0, maxSteps: 1),
            equationPolicy: policy).run(plan: plan, devices: [device], solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(result.variables == [2, 3])
        #expect(gate.sawIntermediate)
    }

    @Test("Source recovery forwards K/W and A/V policy through original source scaling")
    func sourceRecoveryForwardsPolicy() async throws {
        let source = Instance(name: "V1", typeName: "vsource", nodes: [voltage, .ground],
            parameters: ["v": .real(2)], ownedBranches: [flow])
        let balance = Instance(name: "balance", typeName: "test", nodes: [voltage, thermal], parameters: [:])
        let ir = CircuitIR(nodes: [.ground, voltage, thermal], branches: [flow], instances: [source, balance])
        let plan = try StandardCompiler().compile(ir: ir)
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: 3,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        let boundSource = try VoltageSourceDescriptor().bind(instance: source, context: &context)
        let gate = RecoveryGate()
        let device = RecoveryDevice(instance: balance, voltage: voltage, thermal: thermal,
            intermediateVoltage: 1, stampsVoltage: false, gate: gate)
        let policy = try DCEquationPolicy(rows: [row(.electricalPotential), row(.thermalPotential),
            row(.electricalFlow)])
        let result = try await DCAnalysis(config: .init(reltol: 0, maxIterations: 2, gmin: 0),
            gminStepping: .init(initialGmin: 0, finalGmin: 0, maxSteps: 0), sourceStepping: .init(steps: 2),
            equationPolicy: policy).run(plan: plan, devices: [boundSource, device], solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(result.variables == [2, 3, 0])
        #expect(gate.sawIntermediate)
    }

    @Test("Direct physical rejection precedes accepted commits and completed publication")
    func physicalValidationPrecedesCommit() async throws {
        let instance = Instance(name: "test", typeName: "test", nodes: [voltage, .ground], parameters: [:])
        let ir = CircuitIR(nodes: [.ground, voltage], branches: [], instances: [instance])
        let plan = try StandardCompiler().compile(ir: ir)
        let commits = CommitCounter()
        let device = CommittingDevice(instance: instance, counter: commits)
        let observer = try BufferingObserver(capacity: 100)
        let dispatcher = EventDispatcher(observers: [observer])
        let policy = try DCEquationPolicy(rows: [row(.electricalPotential)])
        for reject in [true, false] {
            do {
                let result = try await DCAnalysis(config: .init(gmin: 0), equationPolicy: policy,
                    physicalResidualValidator: PhysicalValidator(reject: reject)).run(plan: plan,
                    devices: [device], solver: SparseLUSolver(), observer: dispatcher,
                    cancellation: CancellationToken())
                #expect(!reject)
                #expect(result.variables == [1])
            } catch PhysicalFailure.unsatisfiedOriginalEquation {
                #expect(reject)
                #expect(commits.count == 0)
            }
            let statuses = observer.events.compactMap { event -> AnalysisStatus? in
                if case .analysisFinished(let info) = event { return info.status }
                return nil
            }
            #expect(statuses == [reject ? .failed : .completed])
        }
        #expect(commits.count == 1)
    }
}

private struct InaccurateSolver: LinearSolver {
    mutating func factorize(matrix: SparseMatrix) throws {}
    func solve(rhs: [Double]) throws -> [Double] { [100_000_001] }
}

private enum PhysicalFailure: Error { case unsatisfiedOriginalEquation }

private struct PhysicalValidator: DCPhysicalResidualValidating {
    let reject: Bool
    func validate(state: SolutionState) throws {
        #expect(state.variables == [1])
        if reject { throw PhysicalFailure.unsatisfiedOriginalEquation }
    }
}

private final class CommitCounter: Sendable {
    private let state = Mutex(0)
    var count: Int { state.withLock { $0 } }
    func increment() { state.withLock { $0 += 1 } }
}

private struct CommittingDevice: AcceptedStateCommittingDevice {
    let instance: Instance
    let counter: CommitCounter
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        stamper.stampMatrix(0, 0, 1); stamper.stampRHS(0, 1)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {}
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {}
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
    func commitAcceptedState(_ state: SolutionState) { counter.increment() }
}

private final class RecoveryGate: Sendable {
    private let state = Mutex(false)
    var sawIntermediate: Bool { state.withLock { $0 } }
    func admit(voltage: Double, thermal: Double, intermediate: Double) -> ConvergenceResult {
        state.withLock { seen in
            guard abs(thermal - 3) < 1e-12 else { return .notConverged(maxDelta: abs(thermal - 3), deviceName: "thermal") }
            if abs(voltage - intermediate) < 1e-12 { seen = true }
            return seen ? .converged : .notConverged(maxDelta: abs(voltage - intermediate), deviceName: "recovery")
        }
    }
}

private struct RecoveryDevice: BoundDevice {
    let instance: Instance
    let voltage: Node
    let thermal: Node
    let intermediateVoltage: Double
    let stampsVoltage: Bool
    let gate: RecoveryGate
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        let thermalIndex = stamper.nodeIndex(thermal)!
        stamper.stampMatrix(thermalIndex, thermalIndex, 1); stamper.stampRHS(thermalIndex, 3)
        if stampsVoltage {
            let voltageIndex = stamper.nodeIndex(voltage)!
            stamper.stampMatrix(voltageIndex, voltageIndex, 1); stamper.stampRHS(voltageIndex, 2)
        }
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {}
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {}
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        gate.admit(voltage: state.voltage(at: voltage), thermal: state.voltage(at: thermal),
            intermediate: intermediateVoltage)
    }
}
