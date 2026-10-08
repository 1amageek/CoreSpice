import Testing
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
        let ir = try NetlistLowering().lower(parsed)
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
        #expect(unresolved.subcircuits[0].body.components[0].resistorModelCandidate == "rv")
        #expect(unresolved.subcircuits[0].body.components[1].resistorModelCandidate == nil)
        let serialized = SPICESerializer().serialize(unresolved)
        let roundTrip = try await SPICEParser().parse(source: serialized).get()
        #expect(roundTrip.subcircuits[0].body.components[0].resistorModelCandidate == "rv")
        #expect(roundTrip.subcircuits[0].body.components[1].resistorModelCandidate == nil)
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
            let ir = try NetlistLowering().lower(input)
            let bare = try #require(ir.instances.first { $0.name.lowercased() == "x1.rbare" })
            let numeric = try #require(ir.instances.first { $0.name.lowercased() == "x1.rnumeric" })
            #expect(bare.model?.name == "rv")
            #expect(scalar(bare.model?.parameters["r"]) == 200)
            #expect(bare.parameters["r"] == nil)
            #expect(numeric.model == nil)
            #expect(scalar(numeric.parameters["r"]) == 100)
            #expect(bare.parameters["resistorModelCandidate"] == nil)
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
        let ir = try NetlistLowering().lower(parsed)
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

    @Test func runtimeResistanceRetainsDependenciesAndBindingRefuses() async throws {
        let parsed = try await SPICEParser().parse(source: """
        runtime resistor refusal
        .subckt cell a b c
        R1 a b r={100+V(c,b)}
        .ends
        X1 in 0 sense cell
        .end
        """).get()
        let ir = try NetlistLowering().lower(parsed)
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
        #expect(throws: DeviceBindingError.self) { _ = try ResistorDescriptor().bind(instance: instance, context: &context) }
    }

    @Test func unknownAndMismatchedModelRefuse() async throws {
        for source in ["R1 a 0 missing r=100", "R1 a 0 diode r=100\n.model diode D"] {
            let parsed = try await SPICEParser().parse(source: "refusal\n\(source)\n.end\n").get()
            #expect(throws: LoweringError.self) { _ = try NetlistLowering().lower(parsed) }
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
        let ir = try NetlistLowering(configuration: .init(geometryScale: 2e-6)).lower(parsed)
        #expect(abs(try #require(scalar(ir.instances[0].parameters["l"])) - 20e-6) < 1e-20)
        for scale in [0.0, -1.0, .infinity] {
            #expect(throws: LoweringError.self) {
                _ = try NetlistLowering(configuration: .init(geometryScale: scale)).lower(parsed)
            }
        }
        let mos = try await SPICEParser().parse(source: """
        unsupported scaled mos
        .options scale=1u
        M1 d g 0 0 channel l=.15 w=.65
        .model channel NMOS level=1
        .end
        """).get()
        #expect(throws: LoweringError.self) { _ = try NetlistLowering().lower(mos) }
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
