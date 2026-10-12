import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

@main
struct EnvironmentProbe {
    static func main() throws {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 2_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 8, maximumSymbols: 32, maximumScopes: 8,
            maximumInvocations: 8, maximumInvocationBindings: 32, maximumDeclarations: 8,
            maximumPrograms: 32, maximumBindings: 32, maximumFunctions: 8,
            maximumFunctionDepth: 8, maximumExpressionNodes: 128, maximumExpressionDepth: 32,
            maximumCandidates: 8, maximumCacheEntries: 32, maximumEvaluationSteps: 100_000)
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let scope = try builder.addScope(parent: nil)
        let a = try builder.intern("a"), temper = try builder.intern("temper"), random = try builder.intern("rand")
        let randomProgram = try builder.addProgram(.function(random, arguments: []))
        _ = try builder.addBinding(symbol: a, scope: scope, program: randomProgram)
        let ambient = try builder.addProgram(.binary(.add, .literal(20), .reference(a)))
        let nominal = try builder.addProgram(.binary(.add, .reference(temper), .literal(5)))
        let snapshot = try builder.finish()
        let invocation = try MOSScopeInvocation(id: 0, scope: scope, callerInvocationID: nil, actuals: [], limits: limits)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [invocation], limits: limits)
        let bootstrap = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph, seed: 4, limits: limits)
        var session = try bootstrap.freeze(ambient: .program(ambient, invocation: 0, lexicalScope: scope),
            nominal: .program(nominal, invocation: 0, lexicalScope: scope))
        let first = try evaluateMOSBinding(a, invocation: 0, from: snapshot, session: &session)
        precondition(first == 2422386115650570.0 / 9007199254740992.0)
        precondition(session.randomDraws == 1)
        let second = try evaluateMOSProgram(randomProgram, invocation: 0, lexicalScope: scope, from: snapshot, session: &session)
        precondition(first != second && session.randomDraws == 2)
        guard let environment = session.environment else { preconditionFailure("Missing frozen environment") }
        precondition(abs(environment.ambient.value - (293.15 + first)) < 1e-12)
        precondition(abs(environment.nominal.value - environment.ambient.value - 5) < 1e-12)
        let provenance = session.finishProvenance()
        precondition(provenance.environment?.identity == environment.identity)
        let cyclic = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph, seed: 4, limits: limits)
        do {
            _ = try cyclic.freeze(ambient: .program(nominal, invocation: 0, lexicalScope: scope),
                nominal: .temperature(TemperatureKelvin(300.15)))
            preconditionFailure("Ambient cycle accepted")
        } catch let error as MOSConditionEvaluationFailure { precondition(error.cause == .conditionCycle(.ambient)) }
        print("D2 bootstrap/freeze, memo, random continuity, identity and cycle refusal passed")
    }
}
