import CoreSpiceEvaluationContracts
import Testing
import Synchronization
import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

@Suite("Frozen temperature evaluation", .timeLimit(.minutes(1)))
struct ConditionEvaluationTests {
    func limits(steps: UInt64 = 1_000_000, diagnosticBytes: UInt64 = 4096) throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: 16_000_000, maximumDiagnosticBytes: diagnosticBytes,
            maximumScopeDepth: 32, maximumSymbols: 1024, maximumScopes: 128,
            maximumInvocations: 128, maximumInvocationBindings: 1024, maximumDeclarations: 128,
            maximumPrograms: 2048, maximumBindings: 1024, maximumFunctions: 128,
            maximumFunctionDepth: 32, maximumExpressionNodes: 4096, maximumExpressionDepth: 64,
            maximumCandidates: 128, maximumCacheEntries: 2048, maximumEvaluationSteps: steps)
    }
    @Test func scalarTemperResolvesAfterSourceAmbient() throws {
        let source = ParsedNetlist(components: [ParsedComponent(name: "r1", type: .resistor,
            nodes: ["a", "0"], parameters: ["r": .expression(.identifier("value"))])],
            controls: [.temp(value: .numeric(30), location: nil)],
            parameters: ["value": .binaryOperation(.add, .literal(100), .identifier("temper"))])
        let limits = try limits()
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 4)
        try session.lower()
        let result = try session.finish()
        guard case .real(let resistance) = result.circuit.instances[0].parameters["r"] else { Issue.record("Missing scalar resistance"); return }
        #expect(resistance == 130)
    }
}

extension ConditionEvaluationTests {
    func source(controls: [ParsedControlStatement], parameters: [String: ParsedExpression] = [:],
                functions: [ParsedFunctionDefinition] = []) -> ParsedNetlist {
        .init(components: [.init(name: "r1", type: .resistor, nodes: ["a", "0"], parameters: ["r": .numeric(100)])],
            controls: controls, parameters: parameters, functionDefinitions: functions)
    }
    func lower(_ source: ParsedNetlist, policy: NetlistTemperaturePolicy? = nil) throws -> LoweredCircuit {
        let limits = try limits()
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1,
            limits: limits, seed: 4, temperaturePolicy: policy)
        try session.lower()
        return try session.finish()
    }
    @Test func conditionPrecedenceSkipsDeadExpressionsAndKeepsOrigins() throws {
        let controls: [ParsedControlStatement] = [
            .temp(value: .expression(.identifier("missing")), location: nil),
            .option(name: "TEMP", value: .numeric(40), location: nil),
            .temp(value: .numeric(30), location: nil),
            .option(name: "tnom", value: .expression(.binaryOperation(.add, .identifier("temper"), .literal(5))), location: nil)]
        let result = try lower(source(controls: controls))
        let environment = try #require(result.evaluationProvenance.evaluation.environment)
        #expect(environment.ambient.value == 303.15)
        #expect(environment.nominal.value == 308.15)
        #expect(result.evaluationProvenance.temperatures.ambient == .sourceControl(2))
        #expect(result.evaluationProvenance.temperatures.nominal == .sourceControl(3))
        #expect(result.circuit.evaluationEnvironment == environment.identity)
        let defaults = try NetlistTemperaturePolicy.standard.defaults
        let override = NetlistTemperaturePolicy(defaults: defaults,
            ambientOverride: try TemperatureCelsius(50).kelvin,
            nominalOverride: try TemperatureCelsius(60).kelvin)
        let overridden = try lower(source(controls: controls), policy: override)
        #expect(overridden.evaluationProvenance.evaluation.environment?.ambient.value == 323.15)
        #expect(overridden.evaluationProvenance.evaluation.environment?.nominal.value == 333.15)
        #expect(overridden.evaluationProvenance.temperatures.ambient == .callerOverride)
        #expect(overridden.evaluationProvenance.temperatures.nominal == .callerOverride)
        let defaulted = try lower(source(controls: []))
        #expect(defaulted.evaluationProvenance.temperatures.ambient == .callerDefault)
        #expect(defaulted.evaluationProvenance.evaluation.environment?.identity == defaults.identity)
    }
    @Test func memoAndRandomStateContinueAcrossFreezeAndWinningSlotReads() throws {
        let deck = source(controls: [
            .temp(value: .expression(.functionCall(name: "rand", arguments: [])), location: nil),
            .temp(value: .expression(.binaryOperation(.add, .literal(20), .identifier("a"))), location: nil),
            .option(name: "tnom", value: .expression(.binaryOperation(.add, .literal(20), .identifier("b"))), location: nil)],
            parameters: ["a": .functionCall(name: "rand", arguments: []), "b": .functionCall(name: "rand", arguments: []), "tail": .functionCall(name: "rand", arguments: [])])
        let limits = try limits()
        let compiled = try NetlistLowering.compile(deck, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 4)
        let slot = try compiled.scalarSlot(at: .control(index: 1, field: "value"))
        let first = try session.evaluateScalar(slot)
        #expect(try session.evaluateScalar(slot) == first)
        let a = try #require(compiled.snapshot.symbol(named: "a"))
        let b = try #require(compiled.snapshot.symbol(named: "b"))
        let tail = try #require(compiled.snapshot.symbol(named: "tail"))
        try session.lower()
        let result = try session.finish()
        #expect(abs(first - (20 + 2422386115650570.0 / 9007199254740992.0)) < 1e-13)
        #expect(result.evaluationProvenance.randomDraws == 3)
        #expect(result.evaluationProvenance.evaluation.evaluatorVersion == "CoreSpice.MOSEvaluator.v2.temperature-freeze")
        #expect(result.evaluationProvenance.rootVisits.filter { if case .binding = $0 { return true }; return false } == [MOSRootVisit.binding(a, invocation: 0), .binding(b, invocation: 0), .binding(tail, invocation: 0)])
        let repeatResult = try lower(deck)
        #expect(repeatResult.circuit.evaluationEnvironment == result.circuit.evaluationEnvironment)
        #expect(repeatResult.evaluationProvenance.rootVisits == result.evaluationProvenance.rootVisits)
    }
    @Test func formalTemperShadowsBuiltinOnlyInsideThatFunction() throws {
        let f = ParsedFunctionDefinition(name: "f", parameters: ["temper"],
            body: .binaryOperation(.add, .identifier("temper"), .literal(1)))
        let ambient = ParsedParameterValue.expression(.functionCall(name: "f", arguments: [.literal(19)]))
        let result = try lower(source(controls: [.temp(value: ambient, location: nil)],
            parameters: ["v": .binaryOperation(.add, .functionCall(name: "f", arguments: [.literal(3)]), .identifier("temper"))], functions: [f]))
        #expect(result.evaluationProvenance.evaluation.environment?.ambient.value == 293.15)
        let g = ParsedFunctionDefinition(name: "g", parameters: ["temper"], body: .identifier("global"))
        let lexical = try lower(source(controls: [.temp(value: .numeric(20), location: nil),
            .option(name: "tnom", value: .expression(.functionCall(name: "g", arguments: [.literal(99)])), location: nil)],
            parameters: ["global": .identifier("temper")], functions: [g]))
        #expect(lexical.evaluationProvenance.evaluation.environment?.nominal.value == 293.15)
    }
    @Test func directAndIndirectAmbientCyclesRetainBoundedDiagnostics() throws {
        for parameters: [String: ParsedExpression] in [[:], ["a": .identifier("b"), "b": .identifier("temper")]] {
            let reference = parameters.isEmpty ? "temper" : "a"
            do {
                _ = try lower(source(controls: [.temp(value: .expression(.identifier(reference)), location: nil)], parameters: parameters))
                Issue.record("Ambient cycle was accepted")
            } catch let failure as MOSConditionEvaluationFailure {
                #expect(failure.cause == .conditionCycle(.ambient))
                let diagnostic = try #require(failure.diagnostic)
                #expect(diagnostic.condition == .ambient)
                #expect(diagnostic.program != nil)
                #expect(diagnostic.conditionDependencies.count == parameters.count)
                if !parameters.isEmpty {
                    #expect(try diagnostic.conditionDependencies.map { try diagnostic.snapshot.name(of: $0.symbol) } == ["a", "b"])
                }
            }
        }
    }
    @Test func reservedBindingsActualsAndInvalidConditionSyntaxRefuse() throws {
        let limits = try limits()
        #expect(throws: MOSResolutionFailure.self) {
            try NetlistLowering.compile(source(controls: [], parameters: ["TeMpEr": .literal(10)]), limits: limits)
        }
        let compiled = try NetlistLowering.compile(source(controls: []), additionalOverrideNames: ["temper"], limits: limits)
        do {
            _ = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 4,
                parameterOverrides: ["TEMPER": 20])
            Issue.record("Reserved actual was accepted")
        } catch let failure as MOSResolutionFailure {
            guard case .reservedParameter = failure else { Issue.record("Wrong reserved-name failure"); return }
        }
        for value: ParsedParameterValue in [.string("30"), .numericVector([20, 30])] {
            #expect(throws: LoweringError.self) {
                try NetlistLowering.compile(source(controls: [.temp(value: value, location: nil)]), limits: limits)
            }
        }
        for (key, value) in [("temp", ParsedParameterValue.numeric(-273.15)), ("tnom", .numeric(-273.15))] {
            do {
                _ = try lower(source(controls: [.option(name: key, value: value, location: nil)]))
                Issue.record("Invalid temperature was accepted")
            } catch let failure as MOSConditionEvaluationFailure {
                #expect(failure.cause == .invalidTemperature(key == "temp" ? .ambient : .nominal, .absoluteZeroOrBelow))
            }
        }
    }
    @Test func sourceFreeSessionRequiresEnvironmentAndRemainsPoisonedAfterFailure() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let scope = try builder.addScope(parent: nil)
        let temper = try builder.intern("temper")
        let program = try builder.addProgram(.reference(temper))
        let literal = try builder.addProgram(.literal(1))
        let snapshot = try builder.finish()
        let invocation = try MOSScopeInvocation(id: 0, scope: scope, callerInvocationID: nil, actuals: [], limits: limits)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [invocation], limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 4, limits: limits)
        do {
            _ = try evaluateMOSProgram(program, invocation: 0, lexicalScope: scope, from: snapshot, session: &session)
            Issue.record("Unfrozen temper was accepted")
        } catch let error as MOSResolutionFailure { #expect(error == .environmentUnavailable) }
        do {
            _ = try evaluateMOSProgram(literal, invocation: 0, lexicalScope: scope, from: snapshot, session: &session)
            Issue.record("Poisoned session was reused")
        } catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
        #expect(session.failureDiagnostic?.cause == .environmentUnavailable)
    }
    @Test func runtimeVariablesAreNotScalarConditions() throws {
        for name in ["time", "hertz"] {
            do {
                _ = try lower(source(controls: [.temp(value: .expression(.identifier(name)), location: nil)]))
                Issue.record("Runtime variable was accepted as a condition")
            } catch let failure as MOSConditionEvaluationFailure {
                guard case .unsupportedScalarVariable = failure.cause else { Issue.record("Wrong scalar variable failure"); return }
            }
        }
    }
}

extension ConditionEvaluationTests {
    private final class Cancellation: MOSResolutionControlling {
        let cancelled = Mutex(false)
        func cancel() { cancelled.withLock { $0 = true } }
        func checkCancellation() throws(MOSResolutionFailure) {
            if cancelled.withLock({ $0 }) { throw .cancelled }
        }
        func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {}
    }
    @Test func bootstrapCancellationWorkExhaustionAndBoundedRootSource() throws {
        let base = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: base)
        let scope = try builder.addScope(parent: nil)
        let temper = try builder.intern("temper")
        let program = try builder.addProgram(.reference(temper))
        let snapshot = try builder.finish()
        let invocation = try MOSScopeInvocation(id: 0, scope: scope, callerInvocationID: nil, actuals: [], limits: base)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [invocation], limits: base)
        let control = Cancellation()
        let cancelled = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph, seed: 4, limits: base, control: control)
        control.cancel()
        do {
            _ = try cancelled.freeze(ambient: .temperature(TemperatureKelvin(300.15)), nominal: .temperature(TemperatureKelvin(300.15)))
            Issue.record("Cancelled bootstrap succeeded")
        } catch let failure as MOSConditionEvaluationFailure { #expect(failure.cause == .cancelled) }
        let exhausted = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph, seed: 4, limits: limits(steps: 1))
        do {
            _ = try exhausted.freeze(ambient: .temperature(TemperatureKelvin(300.15)), nominal: .temperature(TemperatureKelvin(300.15)))
            Issue.record("Exhausted bootstrap succeeded")
        } catch let failure as MOSConditionEvaluationFailure { #expect(failure.cause == .limitExceeded(.evaluationSteps)) }
        let source = MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: "deck.sp", line: 9, column: 1,
            statementByteOffset: nil, statementOrdinal: 2)
        let owner = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph, seed: 4, limits: base)
        do {
            _ = try owner.freeze(ambient: .program(program, invocation: 0, lexicalScope: scope, source: source),
                nominal: .temperature(TemperatureKelvin(300.15)))
            Issue.record("Cycle accepted")
        } catch let failure as MOSConditionEvaluationFailure { #expect(failure.diagnostic?.conditionSource == source) }
        let oversized = MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: String(repeating: "x", count: 4096), line: 9,
            column: 1, statementByteOffset: nil, statementOrdinal: 2)
        let bounded = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph, seed: 4, limits: limits(diagnosticBytes: 768))
        do {
            _ = try bounded.freeze(ambient: .program(program, invocation: 0, lexicalScope: scope, source: oversized),
                nominal: .temperature(TemperatureKelvin(300.15)))
            Issue.record("Cycle accepted")
        } catch let failure as MOSConditionEvaluationFailure {
            #expect(failure.cause == .conditionCycle(.ambient))
            #expect(failure.diagnostic?.conditionSource == nil)
            #expect(failure.diagnostic?.isTruncated == true)
        }
    }
}
