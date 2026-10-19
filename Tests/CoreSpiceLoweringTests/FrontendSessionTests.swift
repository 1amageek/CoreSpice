import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import CoreSpiceParser
import Testing
@testable import CoreSpiceDevices

@Suite("Compiled frontend shared evaluation", .timeLimit(.minutes(1)))
struct FrontendSessionTests {
    @Test func globalRandomIsSharedAcrossOptionsDevicesAndMOSAndAliasesMemoize() async throws {
        let parsed = try await SPICEParser().parse(source: """
        one random binding
        .param shared={rand()}
        .options reltol={shared}
        .ic V(A)={rand()}
        R1 a 0 {shared}
        M1 d g 0 0 nm l=1u w=1u
        .model nm NMOS level=1 vto={shared}
        .end
        """).get()
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 92)
        let optionIndex = try #require(parsed.controls.firstIndex { if case .option = $0 { return true }; return false })
        let option = try session.evaluateScalar(compiled.scalarSlot(at: .control(index: optionIndex, field: "value")))
        let icIndex = try #require(parsed.controls.firstIndex { if case .initialCondition = $0 { return true }; return false })
        let firstIC = try session.evaluateScalar(compiled.scalarSlot(at: .control(index: icIndex, field: "value")))
        let secondIC = try session.evaluateScalar(compiled.scalarSlot(at: .initialCondition(node: "A")))
        #expect(firstIC == secondIC)
        try session.lower()
        let result = try session.finish()
        #expect(scalar(result.circuit.instances[0].parameters["r"]) == option)
        guard case .resolved(let mos) = result.circuit.instances[1].mos else { Issue.record("Missing resolved MOS"); return }
        #expect(coefficient("vto", in: mos) == option)
        #expect(result.evaluationProvenance.randomDraws == 2)
        #expect(result.compiled.sameStorage(as: compiled))
        #expect(result.snapshot.sameStorage(as: compiled.snapshot))
        #expect(result.circuit.instances.allSatisfy { $0.ownedNodes.isEmpty })
    }

    @Test func callerNumericAncestryAndLexicalModelAncestryRemainIndependent() async throws {
        let parsed = try await SPICEParser().parse(source: """
        separate ancestry
        .param p=7
        .model nm NMOS level=1 vto={p}
        .subckt inner a p=1
        M1 a a 0 0 nm l=1u w=1u
        R1 a 0 {p}
        .ends
        .subckt caller a p=3
        .model nm NMOS level=1 vto=99
        Xinside a inner p={p}
        .ends
        X1 a caller p=5
        .end
        """).get()
        let result = try resolved(parsed)
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(coefficient("vto", in: mos) == 7)
        #expect(scalar(result.circuit.instances[1].parameters["r"]) == 5)
        #expect(mos.scopeInstantiation == 2)
    }

    @Test func nonMOSCoefficientsAreIndependentSlotsInFinalParameterEnvironment() async throws {
        let parsed = try await SPICEParser().parse(source: """
        coefficient slots
        .param b=7
        .model rm R r={b} b=2
        R1 a 0 rm
        .end
        """).get()
        let result = try resolved(parsed)
        #expect(scalar(result.circuit.instances[0].model?.parameters["r"]) == 7)
        #expect(scalar(result.circuit.instances[0].model?.parameters["b"]) == 2)
        let missing = try await SPICEParser().parse(source: "slots\n.model rm R r={b} b=2\nR1 a 0 rm\n.end\n").get()
        #expect(throws: MOSResolutionFailure.self) { _ = try resolved(missing) }
    }

    @Test func classicalSelectedSourceAndScaledGeometryRemainInspectable() async throws {
        let source = """
        inspect classical model
        .options scale=1u
        .model nm NMOS level=3 vto=.7
        M1 d g 0 0 nm l=1.5 w=.5
        .end
        """
        let parsed = try await SPICEParser().parse(document: .init(text: source, resolvedPath: "classic.cir", captureID: "classic-capture"),
            configuration: .default, fileResolver: NullFileResolver()).get()
        let limits = try FrontendTestLowering.limits()
        let result = try resolved(parsed)
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(mos.release == .level3)
        #expect(abs(try #require(mos.normalizedGeometry.length) - 1.5e-6) < 1e-20)
        #expect(try inspectResolvedMOS(mos, from: result.snapshot, limits: limits).declaration == mos.declaration)
        #expect(mos.source.captureID == "classic-capture" && mos.source.line == 3)
        #expect(try result.compiled.modelOrigin(for: mos) == parsed.models[0].origin)
        #expect(result.circuit.instances[0].parameters.isEmpty && result.circuit.instances[0].model == nil)
    }

    @Test func compileOnceSupportsDistinctRootActualsAndSeeds() async throws {
        let parsed = try await SPICEParser().parse(source: "repeat\n.param r=1\nR1 a 0 {r+rand()}\n.end\n").get()
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(parsed, additionalOverrideNames: ["extra"], limits: limits)
        var first = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 1, parameterOverrides: ["r": 2, "extra": 7])
        try first.lower(); let one = try first.finish()
        var second = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 2, parameterOverrides: ["r": 5])
        try second.lower(); let two = try second.finish()
        #expect(one.snapshot.sameStorage(as: two.snapshot))
        #expect(one.evaluationProvenance.randomDraws == 1 && two.evaluationProvenance.randomDraws == 1)
        guard case .real(let firstR) = one.circuit.instances[0].parameters["r"], case .real(let secondR) = two.circuit.instances[0].parameters["r"] else { Issue.record("Missing resistor values"); return }
        #expect(firstR >= 2 && firstR < 3)
        #expect(secondR >= 5 && secondR < 6)
    }

    @Test func foreignSlotsPoisonSessionAndResourceEnvelopeChecksOverflow() throws {
        let limits = try FrontendTestLowering.limits()
        let parsed = ParsedNetlist(controls: [.temp(value: .numeric(27), location: nil)])
        let first = try NetlistLowering.compile(parsed, limits: limits), other = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(first, profile: .coreStrictV1, limits: limits, seed: 1)
        do { _ = try session.evaluateScalar(other.scalarSlot(at: .control(index: 0, field: "value"))); Issue.record("Foreign slot must fail") }
        catch let error as MOSResolutionFailure { #expect(error == .conditionMismatch) }
        do { try session.lower(); Issue.record("Poisoned session must fail") }
        catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
        let envelope = try NetlistLowering.resourceEnvelope(limits: limits)
        #expect(envelope.maximumRetainedBytes == 2 * limits.maximumRetainedBytes)
        #expect(envelope.maximumSimultaneousBytes == 3 * limits.maximumRetainedBytes)
        let overflowing = try FrontendTestLowering.limits(maximumRetainedBytes: .max)
        #expect(throws: MOSResolutionFailure.arithmeticOverflow) { _ = try NetlistLowering.resourceEnvelope(limits: overflowing) }
    }

    @Test func runtimeRandomLeavesShareSessionAndLazyStaticBranches() async throws {
        let parsed = try await SPICEParser().parse(source: """
        runtime scalar boundary
        .param p={rand()}
        .func offset(x) {gauss(x+1,0)+V(a)}
        R1 a 0 {p}
        B1 a 0 v={offset(2)+if(0,rand(),1)}
        .end
        """).get()
        let result = try resolved(parsed)
        #expect(result.evaluationProvenance.randomDraws == 3)
        #expect(result.evaluationProvenance.rootVisits.contains { if case .program = $0 { return true }; return false })
        guard case .behavioralExpression(.binary(.add,
            .binary(.add, .constant(3), .variable(.nodeVoltage)), .constant(1))) = result.circuit.instances[1].parameters["v"] else { Issue.record("Expected shared static leaves and runtime node reference"); return }
    }

    @Test func dynamicRuntimeBranchesRefuseRandomScalarCapture() async throws {
        for expression in ["if(V(a),rand(),1)", "V(a)&&rand()", "V(a)?1:rand()"] {
            let parsed = try await SPICEParser().parse(source: "dynamic random\nB1 a 0 v={\(expression)}\n.end\n").get()
            #expect(throws: LoweringError.self) { _ = try resolved(parsed) }
        }
    }

    @Test func signedPowerStaticCaptureMatchesRuntimeMeaning() async throws {
        let parsed = try await SPICEParser().parse(source: "signed power\nR1 a 0 {pwrs(-2,2)}\nB1 b 0 v={pwrs(-2,2)+time}\n.end\n").get()
        let result = try resolved(parsed)
        #expect(scalar(result.circuit.instances[0].parameters["r"]) == -4)
        guard case .behavioralExpression(.binary(.add, .constant(let value), .variable(.time))) = result.circuit.instances[1].parameters["v"] else {
            Issue.record("Expected signed static capture beside runtime time"); return
        }
        #expect(value == -4)
        #expect(result.evaluationProvenance.randomDraws == 0)
    }

    @Test func dynamicRuntimeBranchesRetainPotentiallyInactiveInvalidConstants() async throws {
        for sourceExpression in ["if(V(a),1,1/0)", "V(a)?1:sqrt(-1)"] {
            let parsed = try await SPICEParser().parse(source: "lazy runtime branch\nB1 a 0 v={\(sourceExpression)}\n.end\n").get()
            let result = try resolved(parsed)
            let instance = result.circuit.instances[0]
            guard case .behavioralExpression(let expression) = instance.parameters["v"] else {
                Issue.record("Dynamic branches must remain simulation-time expressions"); continue
            }
            let variables: [MNAVariable: Int] = [.nodeVoltage(instance.nodes[0]): 0]
            let evaluator = try BehavioralExpressionEvaluator(expression: expression, instance: instance,
                context: BindingContext(variableMap: variables, matrixDimension: 1))
            let inactiveInvalid = SolutionState(variables: [1], variableMap: variables)
            #expect(try evaluator.evaluateChecked(state: inactiveInvalid, time: 0).value == 1)
            let activeInvalid = SolutionState(variables: [0], variableMap: variables)
            do {
                _ = try evaluator.evaluateChecked(state: activeInvalid, time: 0)
                Issue.record("Active invalid arithmetic must fail at runtime")
            } catch let error as DeviceBindingError {
                guard case .invalidParameterValue(let device, let parameter, _) = error else {
                    Issue.record("Expected active expression failure"); continue
                }
                #expect(device == instance.name && parameter == "expression")
            }
            #expect(result.evaluationProvenance.randomDraws == 0)
        }
    }

    @Test func orderedParserDefaultsWinAndDuplicateActualsAreRejected() async throws {
        let parsed = try await SPICEParser().parse(source: """
        ordered source metadata
        .subckt cell a r=1 r=2
        .param r=3 r=4
        R1 a 0 {r}
        .ends
        X1 a cell
        .end
        """).get()
        let result = try resolved(parsed)
        #expect(scalar(result.circuit.instances[0].parameters["r"]) == 4)
        let duplicate = try await SPICEParser().parse(source: "duplicates\n.subckt cell a r=1\nR1 a 0 {r}\n.ends\nX1 a cell r=2 r=3\n.end\n").get()
        #expect(throws: LoweringError.self) { _ = try resolved(duplicate) }
    }

    @Test func fallbackNodeAliasesRejectDifferentValuesAndShareIdenticalValues() throws {
        let limits = try FrontendTestLowering.limits()
        #expect(throws: MOSResolutionFailure.invalidRequest) {
            _ = try NetlistLowering.compile(.init(initialConditions: ["A": .numeric(1), "a": .numeric(2)]), limits: limits)
        }
        let compiled = try NetlistLowering.compile(.init(initialConditions: ["A": .numeric(1), "a": .numeric(1)]), limits: limits)
        #expect(try compiled.scalarSlot(at: .initialCondition(node: "A")) == compiled.scalarSlot(at: .initialCondition(node: "a")))
        let controlled = try NetlistLowering.compile(.init(controls: [.initialCondition(node: "a", voltage: .numeric(3), location: nil)],
            initialConditions: ["A": .numeric(1), "a": .numeric(2)]), limits: limits)
        var session = try NetlistLowering.beginEvaluation(controlled, profile: .coreStrictV1, limits: limits, seed: 1)
        #expect(try session.evaluateScalar(controlled.scalarSlot(at: .initialCondition(node: "A"))) == 3)
    }





    @Test func MOSInitialConditionVectorAndCanonicalAssignmentsCannotCollide() async throws {
        for assignments in ["ic=.5,1.1 ic_vgs=2", "ic_vgs=2 ic=.5", "ic=.5 ic=1.1"] {
            let parsed = try await SPICEParser().parse(source: "initial collision\nM1 d g 0 0 nm l=1u w=1u \(assignments)\n.model nm NMOS level=1\n.end\n").get()
            #expect(throws: LoweringError.self) { _ = try resolved(parsed) }
        }
        let malformed = ParsedComponent(name: "M1", type: .mosfet, nodes: ["d", "g", "0", "0"], modelName: "nm",
            parameters: ["l": .numeric(1e-6), "w": .numeric(1e-6)],
            parameterAssignments: [.init(name: "ic", value: .numeric(1), additionalValues: [.numeric(2), .numeric(3), .numeric(4)])])
        let input = ParsedNetlist(components: [malformed], models: [.init(name: "nm", type: .nmos, level: 1)])
        #expect(throws: LoweringError.self) { _ = try resolved(input) }
    }

    private func resolved(_ parsed: ParsedNetlist) throws -> LoweredCircuit {
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
        try session.lower(); return try session.finish()
    }
    private func scalar(_ parameter: ParameterValue?) -> Double? {
        guard case .real(let value) = parameter else { return nil }; return value
    }
    private func coefficient(_ name: String, in mos: ResolvedMOSInstance) -> Double? {
        mos.modelCoefficients.first { mos.symbolNames[Int($0.symbol.rawValue)] == name }?.value
    }
}
