@testable import CoreSpice
import Testing

@Suite(.timeLimit(.minutes(1)))
struct NativeCanonicalTransientGateTests {
    private enum FixtureFailure: Error { case unexpectedStamp }
    private struct Equations: TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing, TransientPhysicalResidualContributing {
        let instance = Instance(name: "physical-terms", typeName: "fixture", nodes: [Node(id: 1)], parameters: [:])
        var paired = false
        var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
        func validateTransientPhysicalEquationDecomposition() throws { }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { throw FixtureFailure.unexpectedStamp }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { throw FixtureFailure.unexpectedStamp }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws { throw FixtureFailure.unexpectedStamp }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
        func accumulateTransientStaticResidual(state: SolutionState, time: Double, add: (Int, Double) -> Void) throws {
            #expect(time == 0); add(0, state.variables[0])
        }
        func accumulateTransientStaticResidualEnclosure(state: SolutionState, time: Double,
            add: (Int, CompensatedValue, Double) -> Void) throws {
            #expect(time == 0); add(0, try .init(high: state.variables[0], low: state.variableLowComponents?[0] ?? 0), 0)
        }
        func increment(_ integration: IntegrationState) -> Double {
            integration.currentTime == 1 ? -4.1514507428965264e-7 : -8.302957805346787e-7
        }
        func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
            add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
            add(0, .staticResidual, state.variables[0]); add(0, .chargeDifference, increment(integration))
        }
        func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
            add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
            add(0, .staticResidual, try .init(high: state.variables[0], low: state.variableLowComponents?[0] ?? 0), 0)
            add(0, .chargeDifference, try .init(high: paired ? -1 : increment(integration)), 0)
        }
        func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
            add(0, state.variables[0] + increment(integration) - (integration.method == .trapezoidal ? -4.1514507428965264e-7 : 0))
        }
    }
    private let map: [MNAVariable: Int] = [.nodeVoltage(Node(id: 1)): 0]
    private func budget() throws -> TransientExecutionBudget {
        try .init(limits: .init(maximumAcceptedSteps: 10, maximumSolveAttempts: 100, maximumNewtonIterations: 100,
            maximumSavedScalars: 100, maximumMatrixDimension: 1, maximumWorkUnits: 100_000, maximumBreakpoints: 10),
            dimension: 1, nonZeroCount: 1, deviceCount: 1)
    }
    private func rows(_ tolerance: Double = 1e-12) throws -> [DCEquationRowPolicy] {
        [try .init(kind: .thermalPotential, variableAbsoluteTolerance: 1e-6, equationAbsoluteTolerance: tolerance)]
    }

    @Test func companionPassingActualDiagnosticRowStillFailsCanonicalAndRejectedTrialsDoNotPromote() throws {
        let provider = Equations(), policies = try rows(), token = CancellationToken()
        let canonical = try NativeOSDICanonicalTransientValidator(devices: [provider], precision: false,
            rows: policies, variableMap: map, budget: budget(), cancellation: token)
        let validator = NativeOSDITransientValidator(contributors: [provider], rows: policies,
            workspace: NativePhysicalResidualWorkspace(count: 1), cancellation: token, canonical: canonical)
        let first = SolutionState(variables: [4.1514584635887698e-7], previousVariables: [0], variableMap: map)
        try validator.validate(state: first, integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 1))
        canonical.promote(time: 1)
        let rejected = SolutionState(variables: [4.1515103396217394e-7], previousVariables: first.variables, variableMap: map)
        let tr = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 2)
        var companion = 0.0
        try validator.accumulateResidual(state: rejected, integration: tr) { _, value in companion += value }
        #expect(abs(companion) < 1e-12)
        for _ in 0..<2 {
            do { try validator.validate(state: rejected, integration: tr); Issue.record("Canonical thermal violation passed") }
            catch let error as SPICEOSDIPhysicalResidualFailure {
                #expect(error.row == 0 && error.absoluteTolerance == 1e-12)
                #expect(abs(error.residual - 1.0997863722224293e-12) < 1e-21)
            }
        }
        let retry = SolutionState(variables: [4.1515003396217394e-7], previousVariables: first.variables, variableMap: map)
        try validator.validate(state: retry, integration: tr)
        #expect(throws: (any Error).self) { try canonical.validateCompletion() }
        canonical.promote(time: 2)
        try canonical.validateCompletion()
    }

    @Test func pairedStaticLowComponentCannotDisappearFromCanonicalAdmission() throws {
        let provider = Equations(paired: true)
        let canonical = try NativeOSDICanonicalTransientValidator(devices: [provider], precision: true,
            rows: rows(2e-17), variableMap: map, budget: budget(), cancellation: .init())
        let state = SolutionState(variables: [1], previousVariables: [0], variableMap: map,
            variableLowComponents: [0x1p-54], previousVariableLowComponents: [0])
        #expect(throws: SPICEOSDIPhysicalResidualFailure.self) {
            try canonical.validate(state: state, integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 1))
        }
    }

    @Test func sourceFactComparisonAndCopyWorkUseTheSameCumulativeBudget() throws {
        let shared = try budget(), provider = Equations()
        let validator = NativeOSDITransientValidator(contributors: [provider], rows: try rows(),
            workspace: NativePhysicalResidualWorkspace(count: 1), cancellation: .init(),
            sourceFactBudget: shared, sourceFactWork: 176)
        let state = SolutionState(variables: [4.1514584635887698e-7], previousVariables: [0], variableMap: map)
        let step = IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 1)
        try validator.accumulateResidual(state: state, integration: step) { _, _ in }
        #expect(shared.statistics.workUnits == 176)
        let canonical = try NativeOSDICanonicalTransientValidator(devices: [provider], precision: false,
            rows: rows(), variableMap: map, budget: shared, cancellation: .init(), sourceFactWork: 176)
        try canonical.validate(state: state, integration: step)
        // First canonical invocation includes initial-static capture and its existing row/device work.
        #expect(shared.statistics.workUnits == 176 + 2 * (128 + 4 + 176))
        try shared.chargeWork(100_000 - shared.statistics.workUnits)
        #expect(throws: TransientExecutionError.self) {
            try validator.accumulateResidual(state: state, integration: step) { _, _ in Issue.record("Budget exhaustion reached source evaluation") }
        }
        #expect(shared.statistics.workUnits == 100_000)
    }

    @Test func cancellationAfterValidationDoesNotPublishStaticHistory() throws {
        let token = CancellationToken()
        let canonical = try NativeOSDICanonicalTransientValidator(devices: [Equations()], precision: false,
            rows: rows(), variableMap: map, budget: budget(), cancellation: token)
        try canonical.validate(state: .init(variables: [4.1514584635887698e-7], previousVariables: [0], variableMap: map),
            integration: .init(method: .backwardEuler, timeStep: 1, currentTime: 1))
        token.cancel(); canonical.promote(time: 1)
        #expect(throws: (any Error).self) { try canonical.validateCompletion() }
    }
}
