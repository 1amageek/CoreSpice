import CoreSpiceIO
import CoreSpiceMOSResolution
import Testing

@Suite("IO shared scalar frontend", .timeLimit(.minutes(1)))
struct SPICEFrontendSessionTests {
    @Test(arguments: MOSInputProfile.allCases)
    func optionsDeviceAnalysisAndNodeAssignmentsShareOneMemoizedStream(profile: MOSInputProfile) async throws {
        let parsed = try await SPICEIO.parse("""
        one source evaluation
        .param g=rand()
        .options reltol={0.001+g*0.001} scale={1+rand()} method=trap unknown={absent+rand()}
        .temp {20+rand()}
        R1 out 0 {1+rand()}
        .tran 1n {1n+rand()*1n}
        .ic V(out)={rand()}
        .nodeset V(out)={rand()}
        .end
        """).get()
        let limits = try IOTestFrontend.limits
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: profile, limits: limits, seed: 90210)
        let options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        let repeated = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        #expect(options.geometryScale == repeated.geometryScale)
        #expect(options.temperatureCelsius == repeated.temperatureCelsius)
        #expect(options.convergence.reltol == repeated.convergence.reltol)
        #expect(options.diagnostics.count == 1)
        let scale = try #require(options.geometryScale)
        #expect(scale >= 1 && scale <= 2)
        #expect(options.convergence.reltol >= 0.001 && options.convergence.reltol <= 0.002)
        try session.lower(geometryScale: options.geometryScale)
        let emittedCircuit = session.circuit
        let circuit = try #require(emittedCircuit)
        let stopSlot = try compiled.scalarSlot(at: .analysis(index: 0, field: "stopTime"))
        let resolvedAnalysis = try SPICEAnalysisCommands.resolve(parsed.analyses[0], at: 0, from: compiled, session: &session)
        guard case .transient(let transient) = resolvedAnalysis,
              case .numeric(let stop) = transient.stopTime else { Issue.record("Missing resolved transient command"); return }
        #expect(try session.evaluateScalar(stopSlot) == stop)
        #expect(stop >= 1e-9 && stop <= 2e-9)
        let initial = try SPICENodeVoltageResolver().resolve(.initialConditions, compiled: compiled,
            session: &session, circuit: circuit)
        let nodeset = try SPICENodeVoltageResolver().resolve(.nodeSets, compiled: compiled,
            session: &session, circuit: circuit)
        let controlIndex = try #require(parsed.controls.firstIndex {
            if case .initialCondition = $0 { return true }; return false
        })
        let alias = try session.evaluateScalar(compiled.scalarSlot(at: .control(index: controlIndex, field: "value")))
        #expect(initial.values.first == alias)
        #expect(initial.count == 1 && nodeset.count == 1)
        let lowered = try session.finish()
        #expect(lowered.compiled.sameStorage(as: compiled))
        #expect(lowered.snapshot.identitySpace.sameStorage(as: compiled.snapshot.identitySpace))
        #expect(lowered.evaluationProvenance.profile == profile)
        #expect(lowered.evaluationProvenance.seed == 90210)
        #expect(lowered.evaluationProvenance.randomDraws == 7)
        let resistor = try #require(lowered.circuit.instances.first)
        guard case .real(let resistance) = resistor.parameters["r"] else { Issue.record("Missing evaluated resistor"); return }
        #expect(resistance >= 1 && resistance <= 2)
    }

    @Test func wrongIdentityAndInvalidOptionPoisonBeforePublication() async throws {
        let parsed = try await SPICEIO.parse("text option\n.options method=trap\nR1 out 0 1k\n.end\n").get()
        let limits = try IOTestFrontend.limits
        let first = try NetlistLowering.compile(parsed, limits: limits)
        let other = try NetlistLowering.compile(parsed, limits: limits)
        var wrong = try NetlistLowering.beginEvaluation(first, profile: .coreStrictV1, limits: limits, seed: 1)
        do {
            _ = try SPICEAnalysisOptions.resolve(from: other, session: &wrong)
            Issue.record("Text-only option list bypassed identity check")
        } catch let error as MOSResolutionFailure { #expect(error == .invalidRequest) }
        do { try wrong.lower(); Issue.record("Wrong compiled identity left run usable") }
        catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
        let invalid = try await SPICEIO.parse("invalid option\n.options scale={-1-rand()}\nR1 out 0 1k\n.end\n").get()
        let compiled = try NetlistLowering.compile(invalid, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 1)
        do {
            _ = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
            Issue.record("Negative geometry scale was accepted")
        } catch let error as SPICEAnalysisOptionError {
            guard case .invalidOptionValue(let name, _, _) = error else { throw error }
            #expect(name == "scale")
        }
        do { try session.lower(); Issue.record("Option validation failure left run usable") }
        catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
    }

    @Test func sourceOptionInventoryNeverEvaluatesExpressions() async throws {
        let loaded = try await SPICEDeckLoader.load(source: """
        option inventory
        .options reltol={missing+rand()}
        R1 out 0 1k
        .op
        .end
        """)
        #expect(loaded.coverage.items.first { $0.name == "reltol" }?.status == .supported)
        do {
            _ = try IOTestFrontend.lower(loaded.netlist)
            Issue.record("Actual invocation silently ignored an unresolved numeric option")
        } catch let error as MOSResolutionFailure {
            guard case .undefinedParameter = error else { throw error }
        }
        let unknown = try await SPICEIO.parse("raw option\n.options unknown={missing+rand()} method=trap\nR1 out 0 1k\n.end\n").get()
        let resolved = try SPICEIO.lower(unknown, profile: .coreStrictV1, seed: 42, limits: IOTestFrontend.limits)
        #expect(resolved.evaluationProvenance.randomDraws == 0)
    }

    @Test func explicitPublicPoliciesRetainInspectableResolvedMOS() async throws {
        let result = try await SPICEIO.parseAndLower("""
        retained exact release
        .options scale=1u
        .model nch nmos level=3
        M1 d g 0 0 nch l=1 w=2
        .end
        """, profile: .coreStrictV1, seed: 77, limits: IOTestFrontend.limits)
        let mos = try #require(result.circuit.instances.first)
        guard case .resolved(let resolved) = mos.mos else { Issue.record("No resolved MOS stage"); return }
        #expect(resolved.release == .level3)
        #expect(resolved.geometryScale == 1e-6)
        #expect(resolved.normalizedGeometry.length == 1e-6)
        #expect(resolved.normalizedGeometry.width == 2e-6)
        #expect(mos.model == nil && mos.parameters.isEmpty && mos.ownedNodes.isEmpty)
        _ = try inspectResolvedMOS(resolved, from: result.snapshot, limits: IOTestFrontend.limits)
        #expect(result.evaluationProvenance.seed == 77)
    }
    @Test func selectedAnalysisBridgePreservesShapesAndLeavesUnusedFailureUnevaluated() throws {
        let random: ParsedParameterValue = .expression(.functionCall(name: "rand", arguments: []))
        let gain: ParsedParameterValue = .expression(.identifier("gain"))
        let ac = try ACAnalysisSpec(scaleType: .decade, numberOfPoints: 7,
            startFrequency: gain, stopFrequency: .numeric(100))
        let commands: [ParsedAnalysisCommand] = [
            .op,
            .dc(.init(source: "vin", startValue: random, stopValue: random, stepValue: .numeric(1),
                source2: "vother", startValue2: gain, stopValue2: .numeric(10), stepValue2: .numeric(2))),
            .ac(ac),
            .transient(.init(stopTime: random, stepTime: gain, startTime: .numeric(0), maxStep: .numeric(0.1), useInitialConditions: true)),
            .noise(try .init(outputNode: "out", referenceNode: "ref", inputSource: "vin", scaleType: .octave,
                numberOfPoints: 4, startFrequency: gain, stopFrequency: .numeric(100))),
            .transferFunction(.init(output: "v(out)", input: "vin")),
            .sensitivity(.init(output: "v(out)", acSpec: ac)),
            .monteCarlo(try .init(analysis: .fourier(.init(frequency: random, outputs: ["v(out)"])), iterations: 3, seed: 9)),
            .poleZero(.init(inputNode: "in", inputReference: "0", outputNode: "out", outputReference: "ref", transferType: .voltage, analysisType: .both)),
            .fourier(.init(frequency: gain, outputs: ["v(out)", "i(vin)"])),
            .fourier(.init(frequency: .expression(.identifier("missing")), outputs: ["v(out)"]))
        ]
        let source = ParsedNetlist(analyses: commands, parameters: ["gain": .literal(2)])
        let limits = try IOTestFrontend.limits
        let compiled = try NetlistLowering.compile(source, limits: limits)
        let draws: [UInt64] = [0, 2, 0, 1, 0, 0, 0, 1, 0, 0]
        for index in draws.indices {
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 91)
            try session.lower()
            let actual = try SPICEAnalysisCommands.resolve(commands[index], at: index, from: compiled, session: &session)
            #expect(try SPICEAnalysisCommands.resolve(commands[index], at: index, from: compiled, session: &session) == actual)
            switch actual {
            case .op: break
            case .dc(let spec):
                #expect(spec.source == "vin" && spec.source2 == "vother")
                #expect(spec.startValue2 == .numeric(2)); #expect(spec.stopValue2 == .numeric(10)); #expect(spec.stepValue2 == .numeric(2))
                guard case .numeric = spec.startValue, case .numeric = spec.stopValue else { Issue.record("Unresolved DC fields"); return }
            case .ac(let spec):
                #expect(spec.scaleType == .decade && spec.numberOfPoints == 7)
                #expect(spec.startFrequency == .numeric(2) && spec.stopFrequency == .numeric(100))
            case .transient(let spec):
                #expect(spec.useInitialConditions); #expect(spec.stepTime == .numeric(2)); #expect(spec.startTime == .numeric(0))
                guard case .numeric = spec.stopTime else { Issue.record("Unresolved transient field"); return }
            case .noise(let spec):
                #expect(spec.outputNode == "out" && spec.referenceNode == "ref" && spec.inputSource == "vin")
                #expect(spec.scaleType == .octave && spec.numberOfPoints == 4 && spec.startFrequency == .numeric(2))
            case .transferFunction(let spec): #expect(spec.output == "v(out)" && spec.input == "vin")
            case .sensitivity(let spec): #expect(spec.output == "v(out)" && spec.acSpec?.startFrequency == .numeric(2))
            case .monteCarlo(let spec):
                #expect(spec.iterations == 3 && spec.seed == 9)
                guard case .fourier(let inner) = spec.analysis, case .numeric = inner.frequency else { Issue.record("Unresolved nested MC field"); return }
                #expect(inner.outputs == ["v(out)"])
            case .poleZero(let spec): #expect(spec.inputNode == "in" && spec.outputReference == "ref" && spec.analysisType == .both)
            case .fourier(let spec): #expect(spec.frequency == .numeric(2) && spec.outputs == ["v(out)", "i(vin)"])
            }
            let finished = try session.finish()
            #expect(finished.evaluationProvenance.randomDraws == draws[index])
        }
        var wrong = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 91)
        do {
            _ = try SPICEAnalysisCommands.resolve(.op, at: 1, from: compiled, session: &wrong)
            Issue.record("Command from another index was accepted")
        } catch let error as MOSResolutionFailure { #expect(error == .invalidRequest) }
        do { try wrong.lower(); Issue.record("Wrong command left run usable") }
        catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
    }

    @Test func widthFlagUsesOneScalarEvaluationAcrossIOAndLowering() async throws {
        let parsed = try await SPICEIO.parse("""
        Shared width flag
        .options wnflag={rand()<1}
        .model n nmos level=1
        M1 d g 0 0 n l=1u w=4u
        .end
        """).get()
        let limits = try IOTestFrontend.limits
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
        let first = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        let second = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        #expect(first.diagnostics.isEmpty && second.diagnostics.isEmpty)
        try session.lower(geometryScale: first.geometryScale)
        let lowered = try session.finish()
        #expect(lowered.evaluationProvenance.randomDraws == 1)
        guard case .resolved(let mos) = lowered.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(mos.symbolNames[Int(mos.selectedName.rawValue)] == "n")
        #expect(mos.normalizedGeometry.width == 4e-6 && mos.selectionGeometry.width == 4e-6)
    }

    @Test func invalidWidthOptionPoisonsIOEvaluation() async throws {
        for value in ["2", "-1", "\"bad\"", ""] {
            let text = "Invalid width\n.options wnflag\(value.isEmpty ? "" : "=" + value)\nR1 a 0 1k\n.end\n"
            let parsed = try await SPICEIO.parse(text).get()
            let limits = try IOTestFrontend.limits
            let compiled = try NetlistLowering.compile(parsed, limits: limits)
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
            #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "wnflag"))) {
                _ = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
            }
            #expect(throws: MOSResolutionFailure.poisonedSession) { try session.lower() }
            #expect(session.circuit == nil)
        }
    }

}
