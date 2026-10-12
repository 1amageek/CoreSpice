import CoreSpiceParser
import Synchronization
import Testing
import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR
import CoreSpiceParserSPICE

@Suite("D3 diode resolution", .timeLimit(.minutes(1)))
struct DiodeResolutionTests {
    func limits(bytes: UInt64 = 16_000_000, diagnostic: UInt64 = 4096, work: UInt64 = 1_000_000,
                candidates: Int = 128, cache: Int = 2048) throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: bytes, maximumDiagnosticBytes: diagnostic,
            maximumScopeDepth: 32, maximumSymbols: 1024, maximumScopes: 128,
            maximumInvocations: 128, maximumInvocationBindings: 1024, maximumDeclarations: 128,
            maximumPrograms: 2048, maximumBindings: 1024, maximumFunctions: 128,
            maximumFunctionDepth: 32, maximumExpressionNodes: 4096, maximumExpressionDepth: 64,
            maximumCandidates: candidates, maximumCacheEntries: cache, maximumEvaluationSteps: work)
    }
    func lower(_ parsed: ParsedNetlist, scale: Double? = nil, profile: DiodeInputProfile? = .coreDiodeV1,
               mos: MOSInputProfile = .coreStrictV1, policy: NetlistTemperaturePolicy? = nil,
               limits supplied: MOSResolutionLimits? = nil) throws -> LoweredCircuit {
        let limits = try supplied ?? limits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: mos, limits: limits, seed: 4,
                                                         temperaturePolicy: policy)
        try session.lower(geometryScale: scale, diodeProfile: profile)
        return try session.finish()
    }
    func raw(_ text: String) async throws -> ParsedNetlist {
        try await SPICEParser().parse(source: text, fileName: "diode.cir").get()
    }
    func circuit(model: [ParsedParameterAssignment] = [], instance: [ParsedParameterAssignment] = []) -> ParsedNetlist {
        .init(components: [ParsedDiodeInput.component(name: "d1", nodes: ["a", "0"], model: "dm", assignments: instance)],
              models: [ParsedDiodeInput.model(name: "dm", assignments: model)])
    }
    func assignment(_ name: String, _ value: Double) -> ParsedParameterAssignment { .init(name: name, value: .numeric(value)) }
    func refusal(_ source: ParsedNetlist, cause: DiodeResolutionFailure.Cause,
                 limits: MOSResolutionLimits? = nil) throws {
        do { _ = try lower(source, limits: limits); Issue.record("Accepted invalid diode") }
        catch let error as DiodeResolutionFailure { #expect(error.cause == cause) }
    }
    @Test func directRolesAndNormalization() throws {
        let result = try lower(circuit(model: [assignment("m", 0.4)],
            instance: [assignment("AREA", 3), assignment("pj", 2), assignment("m", 2)]), scale: 1e-6)
        let diode = try #require(result.circuit.instances[0].diode?.resolved)
        #expect(diode.model.input.value(for: .gradingCoefficient) == 0.4)
        #expect(diode.input.multiplicity.value == 2)
        #expect(diode.input.geometry.areaFactor.value == 3)
        #expect(diode.input.geometry.perimeter.value == 2e-6)
        #expect(diode.input.rawGeometry.perimeter?.value == 2)
        #expect(diode.environment == result.circuit.evaluationEnvironment)
        #expect(result.circuit.instances[0].parameters.isEmpty)
        #expect(result.circuit.instances[0].model == nil)
    }
    @Test func rawRolesAndTemperature() async throws {
        let source = try await raw("* D3\n.temp 42\n.options tnom=22 scale=1u\n.model DM D (is={1e-14*(temper+1)} m=.4 tnom=20)\nD1 a 0 dm AREA=3 PJ=2 M=2 temp={temper+5}\n.end\n")
        let result = try lower(source)
        let diode = try #require(result.circuit.instances[0].diode?.resolved)
        #expect(diode.model.input.value(for: .gradingCoefficient) == 0.4)
        #expect(diode.input.multiplicity.value == 2)
        #expect(diode.input.geometry.perimeter.value == 2e-6)
        #expect(diode.model.input.nominalTemperature.value == 293.15)
        let environment = try #require(result.evaluationProvenance.evaluation.environment)
        #expect(try diode.input.effectiveTemperature(in: environment).value == 320.15)
        #expect(diode.model.declaration.sourcePath == "diode.cir")
        #expect(diode.model.declaration.line == 4)
        #expect(diode.orderedAssignmentEvidence)
    }
    @Test func defaultsAreNotRescaled() throws {
        let result = try lower(circuit(), scale: 1e-100)
        let d = try #require(result.circuit.instances[0].diode?.resolved)
        #expect(d.input.geometry.areaFactor.value == 1)
        #expect(d.input.geometry.perimeter.value == 0)
        #expect(d.input.origin(for: .areaFactor) == .schemaDefault)
        #expect(d.model.input.origin(for: .nominalTemperature) == .environmentDefault)
    }
    @Test func unknownAndWrongRoleRefuseEvenZero() throws {
        try refusal(circuit(model: [assignment("mystery", 0)]), cause: .schema(.unknownParameter(name: "mystery", role: .model)))
        try refusal(circuit(model: [assignment("js", 0)]), cause: .schema(.unsupportedParameter(name: "js", role: .model)))
        try refusal(circuit(instance: [assignment("is", 1e-14)]), cause: .schema(.wrongRole(name: "is", requested: .instance)))
        try refusal(circuit(model: [assignment("area", 1)]), cause: .schema(.wrongRole(name: "area", requested: .model)))
    }
    @Test func duplicateAssignmentsAndSelectorsRefuse() throws {
        try refusal(circuit(model: [assignment("m", 0.4), assignment("M", 0.5)]), cause: .schema(.duplicateParameter(.model(.gradingCoefficient))))
        try refusal(circuit(instance: [assignment("m", 2), assignment("M", 3)]), cause: .schema(.duplicateParameter(.instance(.parallelMultiplicity))))
        try refusal(circuit(model: [assignment("level", 1), assignment("LEVEL", 1)]), cause: .duplicateSelector)
        try refusal(circuit(model: [assignment("level", 3)]), cause: .schema(.unsupportedLevel(3)))
        try refusal(circuit(model: [.init(name: "version", value: .string("1"))]), cause: .schema(.unsupportedVersionSelector))
    }
    @Test func nonScalarAndMissingOccurrenceEvidenceRefuse() throws {
        try refusal(circuit(model: [.init(name: "is", value: .string("1e-14"))]), cause: .nonScalarAssignment)
        try refusal(circuit(instance: [.init(name: "area", value: .numericVector([1, 2]))]), cause: .nonScalarAssignment)
        let missing = ParsedNetlist(components: [ParsedDiodeInput.component(name: "d1", nodes: ["a", "0"], model: "dm")],
                                   models: [.init(name: "dm", type: .diode, parameters: ["m": .numeric(0.4)])])
        try refusal(missing, cause: .missingOccurrenceEvidence)
        try refusal(circuit(instance: [assignment("temp", 30), assignment("dtemp", 1)]), cause: .schema(.conflictingTemperatures))
    }
    @Test func sourceTokensCannotDisappear() async throws {
        for tail in ["2", "-2", "off", "unknown", "{2}", "'2'", "ic=0", "area=1,2"] {
            do {
                let source = try await raw("* D3\n.model dm D\nD1 a 0 dm \(tail)\n.end\n")
                _ = try lower(source)
                Issue.record("Accepted trailing syntax: \(tail)")
            } catch { }
        }
    }
    @Test func duplicateModelsKeepBothOrigins() async throws {
        let source = try await raw("* D3\n.model dm D\n.model DM D\nD1 a 0 dm\n.end\n")
        do { _ = try lower(source); Issue.record("Accepted duplicate model") }
        catch let failure as DiodeResolutionFailure {
            #expect(failure.cause == .duplicateModel)
            #expect(failure.candidate(at: 0)?.location?.line == 2)
            #expect(failure.candidate(at: 1)?.location?.line == 3)
        }
    }
    @Test func nearestScopeDoesNotFallbackAndSiblingsAreIsolated() async throws {
        let good = try await raw("* D3\n.model dm D(m=.3)\n.subckt child a\n.model dm D(m=.4)\nD1 a 0 dm m=2\n.ends\nX1 a child\nX2 b child\nD0 c 0 dm\n.end\n")
        let result = try lower(good)
        let ds = try result.circuit.instances.map { try #require($0.diode?.resolved) }
        #expect(ds[0].model.input.value(for: .gradingCoefficient) == 0.4)
        #expect(ds[2].model.input.value(for: .gradingCoefficient) == 0.3)
        #expect(!ds[0].model.sameStorage(as: ds[1].model))
        let bad = try await raw("* D3\n.model dm D\n.subckt child a\n.model dm NPN\nD1 a 0 dm\n.ends\nX1 a child\n.end\n")
        try refusal(bad, cause: .wrongModelType)
    }
    @Test func modelMemoAndRandomDrawsAreOwnedOnce() async throws {
        let source = try await raw("* D3\n.model dm D(is={1e-14*(1+rand())})\nD1 a 0 dm m={1+rand()}\nD2 b 0 dm m={1+rand()}\n.end\n")
        let first = try lower(source), second = try lower(source)
        let a = try #require(first.circuit.instances[0].diode?.resolved), b = try #require(first.circuit.instances[1].diode?.resolved)
        #expect(a.model.sameStorage(as: b.model))
        #expect(first.evaluationProvenance.evaluation.randomDraws == 3)
        #expect(a.input.multiplicity.value == second.circuit.instances[0].diode?.resolved.input.multiplicity.value)
        _ = a.model.input.value(for: .saturationCurrent)
        #expect(first.evaluationProvenance.evaluation.randomDraws == 3)
    }
    @Test func explicitCallerMultiplicityAndImplicitRefusal() async throws {
        let explicit = try await raw("* D3\n.model dm D\n.subckt child a m=1\nD1 a 0 dm m={m}\n.ends\nX1 a child m=3\n.end\n")
        #expect(try lower(explicit).circuit.instances[0].diode?.resolved.input.multiplicity.value == 3)
        let implicit = try await raw("* D3\n.model dm D\n.subckt child a\nD1 a 0 dm\n.ends\nX1 a child m=3\n.end\n")
        do { _ = try lower(implicit, mos: .pinnedNgspiceNormalV1); Issue.record("Accepted implicit multiplier") }
        catch let failure as DiodeResolutionFailure { #expect(failure.cause == .implicitMultiplicity) }
    }
    @Test func environmentMismatchAndNormalizationBounds() throws {
        let d = try #require(lower(circuit(instance: [assignment("dtemp", 5)])).circuit.instances[0].diode?.resolved)
        let other = try EvaluationEnvironment(ambient: TemperatureKelvin(400), nominal: TemperatureKelvin(300))
        #expect(throws: DiodeSchemaFailure.environmentMismatch) { try d.input.effectiveTemperature(in: other) }
        for (pj, scale, expected) in [(Double.greatestFiniteMagnitude, 2.0, DiodeSchemaFailure.normalizationOverflow),
                                      (Double.leastNonzeroMagnitude, 0.5, .normalizationUnderflow)] {
            do { _ = try lower(circuit(instance: [assignment("pj", pj)]), scale: scale); Issue.record("Accepted invalid normalization") }
            catch let failure as DiodeResolutionFailure { #expect(failure.cause == .schema(expected)) }
        }
    }
    @Test func refusalPoisonsSessionAndDoesNotPublishPartialCircuit() throws {
        let limits = try limits()
        let parsed = circuit(model: [assignment("js", 0)])
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 4)
        do { try session.lower(diodeProfile: .coreDiodeV1); Issue.record("Accepted unknown") }
        catch let failure as DiodeResolutionFailure { #expect(!failure.isTruncated); #expect(failure.instance == "d1") }
        #expect(session.circuit == nil)
        do { try session.lower(diodeProfile: .coreDiodeV1); Issue.record("Reused poisoned session") }
        catch let failure as MOSResolutionFailure { #expect(failure == .poisonedSession) }
    }
    @Test func explicitProfileAndSourceProjectionRequired() throws {
        do { _ = try lower(circuit(), profile: nil); Issue.record("Inferred profile") }
        catch let failure as DiodeResolutionFailure { #expect(failure.cause == .profileRequired) }
        let mismatch = ParsedNetlist(components: [ParsedComponent(name: "d1", type: .diode, nodes: ["a", "0"], modelName: "dm",
            parameters: ["area": .numeric(2)], parameterAssignments: [assignment("area", 1)])], models: [ParsedDiodeInput.model(name: "dm")])
        try refusal(mismatch, cause: .inconsistentProjection)
    }
}

extension DiodeResolutionTests {
    @Test func perInvocationModelEvaluationAndBindingMemo() async throws {
        let source = try await raw("* D3\n.subckt child a p=1\n.model dm D(is={p*1e-14} m=.4)\nD1 a 0 dm m={p}\nD2 a 0 dm\n.ends\nX1 a child p=2\nX2 b child p=3\n.end\n")
        let result = try lower(source)
        let ds = try result.circuit.instances.map { try #require($0.diode?.resolved) }
        #expect(ds[0].model.sameStorage(as: ds[1].model))
        #expect(!ds[0].model.sameStorage(as: ds[2].model))
        #expect(ds[0].model.input.value(for: .saturationCurrent) == 2e-14)
        #expect(ds[2].model.input.value(for: .saturationCurrent) == 3e-14)
        #expect(ds[0].input.multiplicity.value == 2)
        #expect(ds[2].input.multiplicity.value == 3)
        let shared = try await raw("* D3\n.param r={rand()}\n.model dm D(is={1e-14*(1+r)})\nD1 a 0 dm m={1+r}\nD2 b 0 dm m={1+r}\n.end\n")
        #expect(try lower(shared).evaluationProvenance.evaluation.randomDraws == 1)
    }
    @Test func scalarFailuresAreStructured() async throws {
        for expression in ["time", "hertz", "v(a)", "i(v1)", "missing"] {
            let source = try await raw("* D3\n.model dm D(is={\(expression)})\nD1 a 0 dm\n.end\n")
            do { _ = try lower(source); Issue.record("Accepted nonscalar or undefined input") }
            catch let failure as DiodeResolutionFailure {
                guard case .evaluation = failure.cause else { Issue.record("Lost evaluation cause"); continue }
                #expect(failure.assignment?.location?.line == 2)
            }
        }
        let cycle = try await raw("* D3\n.param a={b} b={a}\n.model dm D(is={a})\nD1 a 0 dm\n.end\n")
        #expect(throws: (any Error).self) { _ = try lower(cycle) }
        try refusal(circuit(model: [.init(name: "level", value: .boolean(true))]), cause: .nonScalarAssignment)
    }
    @Test func selectedDeclarationOnlyAndResourceLimits() async throws {
        let source = try await raw("* D3\n.model unused D(js=0)\n.model dm D\nD1 a 0 dm\n.end\n")
        #expect(try lower(source).circuit.instances.count == 1)
        let duplicated = try await raw("* D3\n.model dm D\n.model DM D\nD1 a 0 dm\n.end\n")
        try refusal(duplicated, cause: .evaluation(.limitExceeded(.candidates)), limits: limits(candidates: 1))
        #expect(throws: (any Error).self) { _ = try lower(source, limits: limits(bytes: 128)) }
        #expect(throws: (any Error).self) { _ = try lower(source, limits: limits(work: 1)) }
    }
    @Test func suppliedZeroAndNonfiniteAreNotDefaults() throws {
        try refusal(circuit(instance: [assignment("area", 0)]), cause: .schema(.invalidValue(.instance(.areaFactor))))
        try refusal(circuit(instance: [assignment("m", -1)]), cause: .schema(.invalidValue(.instance(.parallelMultiplicity))))
        let explicit = try #require(lower(circuit(instance: [assignment("pj", 0)])).circuit.instances[0].diode?.resolved)
        #expect(explicit.input.origin(for: .perimeter) == .supplied)
        #expect(throws: (any Error).self) { _ = try lower(circuit(model: [assignment("is", .infinity)])) }
    }
}

extension DiodeResolutionTests {
    @Test func instanceFailureRetainsExactAssignmentSource() async throws {
        let source = try await raw("* D3\n.model dm D\nD1 a 0 dm area={missing}\n.end\n")
        do { _ = try lower(source); Issue.record("Accepted undefined instance input") }
        catch let failure as DiodeResolutionFailure {
            #expect(!failure.modelAssignment)
            #expect(failure.assignment?.name == "area")
            #expect(failure.assignment?.location?.line == 3)
        }
    }
}

extension DiodeResolutionTests {
    @Test func diagnosticTextIsBoundedWithoutChangingRefusal() throws {
        let name = String(repeating: "x", count: 5000)
        do { _ = try lower(circuit(model: [assignment(name, 0)]), limits: limits(diagnostic: 1024)); Issue.record("Ignored unknown coefficient") }
        catch let failure as DiodeResolutionFailure {
            #expect(failure.isTruncated)
            #expect(failure.instance == nil)
            #expect(failure.cause == .schema(.unknownParameter(name: "", role: .model)))
        }
    }
}

private struct RepeatedDiodeSource: FileResolver {
    func resolveInclude(path: String, relativeTo: String?) async throws -> SPICESourceDocument {
        .init(text: ".model dm D(m=.4)\n", resolvedPath: "model.inc", captureID: "same-model-source")
    }
    func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> SPICESourceDocument {
        throw FileResolverError.fileNotFound(path: path)
    }
    func readFile(at path: String) async throws -> SPICESourceDocument {
        try await resolveInclude(path: path, relativeTo: nil)
    }
}
private final class DiodeCancellation: MOSResolutionControlling {
    let state = Mutex(false)
    func cancel() { state.withLock { $0 = true } }
    func checkCancellation() throws(MOSResolutionFailure) {
        if state.withLock({ $0 }) { throw .cancelled }
    }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) { try checkCancellation() }
}
extension DiodeResolutionTests {
    @Test func includeReappearanceRetainsBothDeclarationOccurrences() async throws {
        let source = try await SPICEParser().parse(source: "D3\n.include model.inc\n.include model.inc\nD1 a 0 dm\n.end\n",
            fileName: "root.cir", configuration: .init(resolveIncludes: true), fileResolver: RepeatedDiodeSource()).get()
        do { _ = try lower(source); Issue.record("Collapsed repeated include") }
        catch let failure as DiodeResolutionFailure {
            #expect(failure.cause == .duplicateModel)
            #expect(failure.declarationRange?.count == 2)
            #expect(failure.candidate(at: 0)?.origin?.captureID == "same-model-source")
            #expect(failure.candidate(at: 1)?.origin?.captureID == "same-model-source")
        }
    }
    @Test func cancellationPublishesNoPartialCircuitAndPoisonsOwner() throws {
        let control = DiodeCancellation(), limits = try limits()
        let compiled = try NetlistLowering.compile(circuit(), limits: limits, control: control)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1,
            limits: limits, seed: 4, control: control)
        control.cancel()
        #expect(throws: MOSResolutionFailure.cancelled) { try session.lower(diodeProfile: .coreDiodeV1) }
        #expect(session.circuit == nil)
        #expect(throws: MOSResolutionFailure.poisonedSession) { try session.lower(diodeProfile: .coreDiodeV1) }
    }
}
