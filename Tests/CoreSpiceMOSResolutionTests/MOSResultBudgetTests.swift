import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Composed MOS result validation budget")
struct MOSResultBudgetTests {
    @Test func finalResultValidationSharesCumulativeEvaluationWork() throws {
        var fixture = try MOSSelectionFixture()
        _ = try fixture.builder.addModel(name: "n", scope: fixture.root, polarity: .nmos,
            level: 1, version: nil, coefficients: [], source: MOSSelectionFixture.source("n"))
        let snapshot = try fixture.finish()
        let graph = try fixture.graph(snapshot)
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 8_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 32, maximumSymbols: 256, maximumScopes: 32,
            maximumInvocations: 64, maximumInvocationBindings: 512, maximumDeclarations: 128,
            maximumPrograms: 256, maximumBindings: 256, maximumFunctions: 32, maximumFunctionDepth: 32,
            maximumExpressionNodes: 256, maximumExpressionDepth: 128, maximumCandidates: 128,
            maximumCacheEntries: 256, maximumEvaluationSteps: 3500)
        let request = try fixture.request([], instance: String(repeating: "m", count: 1000))
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: limits)
        #expect(throws: MOSResolutionFailure.limitExceeded(.evaluationSteps)) {
            try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        }
        #expect(session.failureDiagnostic?.cause == .limitExceeded(.evaluationSteps))
    }
}
