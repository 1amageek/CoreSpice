import CircuiteFoundation
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import OSDIContracts
import Testing

@Suite("Explicit OSDI source admission", .timeLimit(.minutes(1)))
struct OSDIFrontendTests {
    func limits(bytes: UInt64 = 8 * 1024 * 1024) throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: bytes, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 128, maximumScopes: 32,
            maximumInvocations: 32, maximumInvocationBindings: 128, maximumDeclarations: 32,
            maximumPrograms: 128, maximumBindings: 128, maximumFunctions: 32,
            maximumFunctionDepth: 16, maximumExpressionNodes: 128, maximumExpressionDepth: 16,
            maximumCandidates: 32, maximumCacheEntries: 128, maximumEvaluationSteps: 100_000)
    }
    func input(model: String = "foreign", text: String = "typed") throws -> OSDIResolvedInstance {
        let artifact = try ArtifactReference(digest: .init(algorithm: .sha256,
            hexadecimalValue: String(repeating: "a", count: 64)), byteCount: 123,
            descriptor: .init(role: .input, kind: .model, format: .unknown))
        let binding = try OSDIModelBinding(modelName: model, artifact: artifact, descriptorIndex: 2,
            expectedDescriptorName: "exact", modelParameters: [
                .init(name: "same", scope: .model, value: .integer(4)),
                .init(name: "label", scope: .model, value: .string(text))])
        return try .init(binding: binding,
            instanceParameters: [.init(name: "same", scope: .instance, value: .real(2.5))], previousState: [1, 2])
    }
    private func lower(_ parsed: ParsedNetlist, catalog: [String: OSDIResolvedInstance], bytes: UInt64 = 8 * 1024 * 1024) throws -> LoweredCircuit {
        let limits = try limits(bytes: bytes)
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1,
            limits: limits, seed: 1)
        try session.lower(osdiInstances: catalog)
        return try session.finish()
    }
    @Test func orderedPortsScopedKindsExplicitStateAndCloneSurviveActualLowering() async throws {
        let parsed = try await SPICEParser().parse(source: "OSDI\n.model foreign osdi\nN1 d g s 0 heat foreign\n.op\n.end\n").get()
        let selected = try input()
        let result = try lower(parsed, catalog: ["n1": selected])
        let instance = try #require(result.circuit.instances.first)
        #expect(instance.typeName == "osdi" && instance.parameters.isEmpty && instance.model == nil)
        #expect(instance.nodes.map { result.circuit.nodeNames[$0] } == ["d", "g", "s", "0", "heat"])
        #expect(instance.osdi?.resolved == selected)
        #expect(instance.osdi?.resolved.binding.modelParameters[0].value == .integer(4))
        #expect(instance.osdi?.resolved.instanceParameters[0].value == .real(2.5))
        #expect(instance.osdi?.resolved.previousState == [1, 2])
        #expect(result.circuit.evaluationEnvironment?.ambientKelvinBits == Double(300.15).bitPattern)
    }
    @Test func lexicalSelectionAndExpandedInstanceKeysAreExplicit() async throws {
        let parsed = try await SPICEParser().parse(source: """
        OSDI hierarchy
        .model foreign nmos
        .subckt cell p n
        .model foreign osdi
        N1 p n foreign
        .ends
        X1 out 0 cell
        .end
        """).get()
        let result = try lower(parsed, catalog: ["x1.n1": input(model: "FOREIGN")])
        let instance = try #require(result.circuit.instances.first)
        #expect(instance.name == "x1.n1" && instance.osdi != nil)
        #expect(instance.nodes.map { result.circuit.nodeNames[$0] } == ["out", "0"])
    }
    @Test func missingWrongAndSurplusBindingsRefuseCircuitPublication() async throws {
        let parsed = try await SPICEParser().parse(source: "OSDI\n.model foreign osdi\nN1 p 0 foreign\n.end\n").get()
        for catalog in [[String: OSDIResolvedInstance](), ["n1": try input(model: "wrong")],
                        ["n1": try input(), "typo": try input()]] {
            #expect(throws: LoweringError.self) { try lower(parsed, catalog: catalog) }
        }
    }
    @Test func sourceCoefficientsExpressionsAndMalformedTerminalsHaveCoordinates() async throws {
        for line in ["N1 p 0 foreign w=1", "N1 p 0 foreign w={rand()}", "N1 p 0 {foreign}",
                     "N1 foreign", ".model foreign osdi level=1", ".model foreign osdi (unknown=0)"] {
            let result = try await SPICEParser().parse(source: "OSDI\n\(line)\n.end\n")
            #expect(result.hasErrors)
            let failure = try #require(result.errors.first)
            #expect(failure.location?.line == 2)
            #expect(failure.message.contains("OSDI"))
        }
    }
    @Test func directParsedIRCannotBypassCoefficientFreeProfile() throws {
        let location = SourceLocation(file: "direct.cir", line: 9, column: 4)
        let malformed = ParsedComponent(name: "N1", type: .osdi, nodes: [.init(name: "p")],
            modelName: "foreign", parameters: ["unknown": .expression(.identifier("notBound"))], location: location)
        do {
            _ = try NetlistLowering.compile(.init(components: [malformed], models: [.init(name: "foreign", type: .osdi)]), limits: limits())
            Issue.record("Direct OSDI coefficients were admitted")
        } catch let error as LoweringError {
            #expect(error.diagnostic.code == "lowering.osdi_input")
            #expect(error.diagnostic.location == location)
        }
        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering.compile(.init(models: [.init(name: "foreign", type: .osdi, parameters: ["x": .numeric(0)])]), limits: limits())
        }
    }
    @Test func xNeverBecomesOSDIAndNDoesNotBecomeMOS() async throws {
        let x = try await SPICEParser().parse(source: "OSDI\n.model foreign osdi\nX1 p 0 foreign\n.end\n").get()
        #expect(throws: LoweringError.self) { try lower(x, catalog: ["x1": input()]) }
        let n = try await SPICEParser().parse(source: "OSDI\n.model foreign nmos\nN1 p 0 foreign\n.end\n").get()
        #expect(throws: LoweringError.self) { try lower(n, catalog: ["n1": input()]) }
    }
    @Test func implicitHierarchicalMultiplierCannotDisappear() async throws {
        let parsed = try await SPICEParser().parse(source: "OSDI\n.subckt cell p n\n.model foreign osdi\nN1 p n foreign\n.ends\nX1 out 0 cell m=2\n.end\n").get()
        #expect(throws: LoweringError.self) { try lower(parsed, catalog: ["x1.n1": input()]) }
    }
    @Test func typedCatalogRetentionIsBounded() async throws {
        let parsed = try await SPICEParser().parse(source: "OSDI\n.model foreign osdi\nN1 p 0 foreign\n.end\n").get()
        _ = try lower(parsed, catalog: ["n1": input()], bytes: 100_000)
        #expect(throws: MOSResolutionFailure.self) {
            try lower(parsed, catalog: ["n1": input(text: String(repeating: "a", count: 200_000))], bytes: 100_000)
        }
    }
}
