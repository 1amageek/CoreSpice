import Testing
import CoreSpiceMOSContracts
import CoreSpiceParser
import CoreSpiceParserSPICE
import CoreSpiceParsedIR
import CoreSpiceIR
import CoreSpiceDevices
@testable import CoreSpiceLowering

@Suite("Resistor lowering provenance")
struct ResistorLoweringTests {
    private func scalar(_ value: ParameterValue?) -> Double? {
        guard case .real(let number) = value else { return nil }
        return number
    }

    @Test func explicitNumericIdentifiersDoNotBecomeBareModelReferences() async throws {
        let parsed = try await SPICEParser().parse(source: """
        explicit resistor source syntax
        .param rv=100
        Rbraced a 0 {rv}
        Rquoted a 0 'rv'
        Rnamed a 0 r=rv
        Rbare a 0 rv
        .model rv R r=200
        .end
        """).get()
        for component in parsed.components.prefix(3) {
            #expect(component.modelName == nil)
            #expect(component.parameters["r"] == .expression(.identifier("rv")))
        }
        #expect(parsed.components[3].modelName == "rv")
        let ir = try FrontendTestLowering().lower(parsed)
        for instance in ir.instances.prefix(3) {
            #expect(instance.model == nil)
            #expect(scalar(instance.parameters["r"]) == 100)
        }
        #expect(ir.instances[3].model?.name == "rv")
        #expect(scalar(ir.instances[3].model?.parameters["r"]) == 200)
    }

    @Test func unresolvedBareSyntaxSurvivesSerializerIncludeAndScopedLowering() async throws {
        let includedSource = """
        included resistor source
        .subckt cell a
        Rbare a 0 rv
        Rnumeric a 0 {rv}
        .ends
        .end
        """
        let unresolved = try await SPICEParser().parse(source: includedSource).get()
        #expect(unresolved.subcircuits[0].body.components[0].passiveModelCandidate == "rv")
        #expect(unresolved.subcircuits[0].body.components[1].passiveModelCandidate == nil)
        let serialized = SPICESerializer().serialize(unresolved)
        let roundTrip = try await SPICEParser().parse(source: serialized).get()
        #expect(roundTrip.subcircuits[0].body.components[0].passiveModelCandidate == "rv")
        #expect(roundTrip.subcircuits[0].body.components[1].passiveModelCandidate == nil)
        let root = try await SPICEParser().parse(source: """
        included scope
        .param rv=100
        .include "cell.inc"
        .model rv R r=200
        X1 a cell
        .end
        """, fileName: "root.cir", configuration: .init(resolveIncludes: true),
            fileResolver: ResistorIncludeResolver(content: serialized)).get()
        let assembled = ParsedNetlist(components: root.components, models: root.models,
            subcircuits: roundTrip.subcircuits, parameters: root.parameters)
        for input in [root, assembled] {
            let ir = try FrontendTestLowering().lower(input)
            let bare = try #require(ir.instances.first { $0.name.lowercased() == "x1.rbare" })
            let numeric = try #require(ir.instances.first { $0.name.lowercased() == "x1.rnumeric" })
            #expect(bare.model?.name == "rv")
            #expect(scalar(bare.model?.parameters["r"]) == 200)
            #expect(bare.parameters["r"] == nil)
            #expect(numeric.model == nil)
            #expect(scalar(numeric.parameters["r"]) == 100)
            #expect(bare.parameters["passiveModelCandidate"] == nil)
        }
    }
    @Test func scopedForwardModelIdentityAndStaticExpression() async throws {
        let parsed = try await SPICEParser().parse(source: """
        resistor lowering
        .param rv=120
        .model head R r=400 tnom=25
        .subckt cell a
        R1 a 0 head r={rv*2} tc1=.01
        .model head R r=500 tnom=20
        .ends
        X1 a cell
        R2 b 0 head
        R3 c 0 rv
        .end
        """).get()
        let ir = try FrontendTestLowering().lower(parsed)
        let local = try #require(ir.instances.first { $0.name.lowercased() == "x1.r1" })
        #expect(scalar(local.model?.parameters["r"]) == 500)
        #expect(scalar(local.model?.parameters["tnom"]) == 20)
        #expect(scalar(local.parameters["r"]) == 240)
        #expect(local.parameters["tnom"] == nil)
        let global = try #require(ir.instances.first { $0.name.lowercased() == "r2" })
        #expect(scalar(global.model?.parameters["r"]) == 400)
        #expect(global.parameters["r"] == nil)
        #expect(scalar(ir.instances.first { $0.name.lowercased() == "r3" }?.parameters["r"]) == 120)
    }

    @Test func runtimeResistanceRetainsDependenciesAndBindingSucceeds() async throws {
        let parsed = try await SPICEParser().parse(source: """
        runtime resistor binding
        .subckt cell a b c
        R1 a b r={100+V(c,b)}
        .ends
        X1 in 0 sense cell
        .end
        """).get()
        let ir = try FrontendTestLowering().lower(parsed)
        let instance = try #require(ir.instances.first)
        guard case .behavioralExpression = instance.parameters["r"] else {
            Issue.record("Runtime resistance was not retained as canonical behavioral IR")
            return
        }
        #expect(instance.referencedNodes.contains { ir.nodeNames[$0] == "sense" })
        let map = Dictionary(uniqueKeysWithValues: ir.nodes.filter { $0 != .ground }.enumerated().map {
            (MNAVariable.nodeVoltage($0.element), $0.offset)
        })
        var context = BindingContext(variableMap: map, matrixDimension: map.count)
        let bound = try ResistorDescriptor().bind(instance: instance, context: &context)
        #expect(bound.instance.referencedNodes == instance.referencedNodes)
    }

    @Test func functionTemperatureRemainsRuntimeWithNumericParameterOfSameName() async throws {
        let parsed = try await SPICEParser().parse(source: """
        ambient temperature is runtime
        .param rv=100 temper=999
        .func thermal(x) {x*(1+.01*(temper-27))}
        R1 a 0 r=thermal(rv)
        .end
        """).get()
        do {
            let ir = try FrontendTestLowering().lower(parsed)
            let instance = try #require(ir.instances.first)
            guard case .behavioralExpression(.binary(.multiply, .constant(100),
                .binary(.add, .constant(1), .binary(.multiply, .constant(0.01),
                    .binary(.subtract, .variable(.ambientTemperatureCelsius), .constant(27))))))
                = instance.parameters["r"] else {
                Issue.record("Ambient temperature must survive function inlining and lowering configuration")
                return
            }
            #expect(instance.referencedNodes.isEmpty)
            #expect(instance.referencedBranches.isEmpty)
        }
    }

    @Test func nestedRuntimeResistanceKeepsCanonicalPortsBranchAndModelProvenance() async throws {
        let parsed = try await SPICEParser().parse(source: """
        nested runtime resistance
        .model rm R r=400 tnom=20
        .subckt inner a b s
        R1 a b rm r=100+max(V(a,s),I(Vprobe))+temper
        Vprobe s b 0
        .ends
        .subckt outer x y z
        Xinner x y z inner
        .ends
        Xouter out 0 sense outer
        .end
        """).get()
        let ir = try FrontendTestLowering().lower(parsed)
        let resistor = try #require(ir.instances.first { $0.name.lowercased() == "xouter.xinner.r1" })
        let probe = try #require(ir.instances.first { $0.name.lowercased() == "xouter.xinner.vprobe" })
        #expect(resistor.nodes.map { ir.nodeNames[$0] } == ["out", "0"])
        #expect(Set(resistor.referencedNodes.compactMap { ir.nodeNames[$0] }) == ["out", "sense"])
        #expect(resistor.referencedBranches == probe.ownedBranches)
        #expect(scalar(resistor.model?.parameters["r"]) == 400)
        #expect(scalar(resistor.model?.parameters["tnom"]) == 20)
        guard case .behavioralExpression(.binary(.add, .binary(.add, .constant(100),
            .function(.maximum, let arguments)), .variable(.ambientTemperatureCelsius)))
            = resistor.parameters["r"], arguments.count == 2,
            case .variable(.nodeVoltage(let positive, let negative)) = arguments[0],
            case .variable(.branchCurrentReference(0)) = arguments[1] else {
            Issue.record("Expected canonical voltage, branch and ambient dependencies")
            return
        }
        #expect(ir.nodeNames[positive] == "out")
        #expect(ir.nodeNames[negative] == "sense")
    }

    @Test func runtimeFrequencyRefusesEvenIfNamedParameterExists() async throws {
        for expression in ["100+hertz", "100+V(a)+hertz"] {
            let parsed = try await SPICEParser().parse(source: "frequency refusal\n.param hertz=10\nR1 a 0 r=\(expression)\n.end\n").get()
            do {
                _ = try FrontendTestLowering().lower(parsed)
                Issue.record("Unsupported runtime frequency must not be frozen as a parameter")
            } catch let error as LoweringError {
                guard case .expressionEvaluationFailed(_, let reason) = error else {
                    Issue.record("Expected explicit frequency diagnostic: \(error)")
                    continue
                }
                #expect(reason.contains("hertz"))
                #expect(reason.contains("not supported"))
            }
        }
    }

    @Test func unknownAndMismatchedModelRefuse() async throws {
        for source in ["R1 a 0 missing r=100", "R1 a 0 diode r=100\n.model diode D"] {
            let parsed = try await SPICEParser().parse(source: "refusal\n\(source)\n.end\n").get()
            #expect(throws: LoweringError.self) { _ = try FrontendTestLowering().lower(parsed) }
        }
    }

    @Test func scaleOverrideAndIncompleteMOSConsumerAreExplicit() async throws {
        let parsed = try await SPICEParser().parse(source: """
        scale override
        .options scale=1u
        R1 a 0 sheet l=10 w=4
        .model sheet R rsh=100
        .end
        """).get()
        let ir = try FrontendTestLowering(configuration: .init(geometryScale: 2e-6)).lower(parsed)
        #expect(abs(try #require(scalar(ir.instances[0].parameters["l"])) - 20e-6) < 1e-20)
        for scale in [0.0, -1.0, .infinity] {
            #expect(throws: MOSResolutionFailure.self) {
                _ = try FrontendTestLowering(configuration: .init(geometryScale: scale)).lower(parsed)
            }
        }
        let mos = try await SPICEParser().parse(source: """
        unsupported scaled mos
        .options scale=1u
        M1 d g 0 0 channel l=.15 w=.65
        .model channel NMOS level=1
        .end
        """).get()
        let mosIR = try FrontendTestLowering().lower(mos)
        guard case .resolved(let resolved) = mosIR.instances.first?.mos else { Issue.record("Missing resolved scaled MOS"); return }
        #expect(abs(try #require(resolved.normalizedGeometry.length) - 0.15e-6) < 1e-20)
        #expect(abs(try #require(resolved.normalizedGeometry.width) - 0.65e-6) < 1e-20)
    }
}

private struct ResistorIncludeResolver: FileResolver {
    let content: String
    func resolveInclude(path: String, relativeTo: String?) async throws -> SPICESourceDocument {
        guard path == "cell.inc" else { throw FileResolverError.fileNotFound(path: path) }
        return SPICESourceDocument(text: content, resolvedPath: path)
    }
    func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> SPICESourceDocument {
        throw FileResolverError.fileNotFound(path: path)
    }
    func readFile(at path: String) async throws -> SPICESourceDocument {
        throw FileResolverError.fileNotFound(path: path)
    }
}
