import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("MOS declaration source intake", .timeLimit(.minutes(1)))
struct MOSDeclarationIntakeTests {
    @Test func orderedAssignmentsRetainDuplicatesRolesAndPhysicalLocations() async throws {
        let source = """
        MOS source roles
        .model mf nmos level=54 version=4.8.1 vth0=.4
        + vth0=.5 vtho=.6
        .subckt cell d g s b w=1u w=2u
        .param gain=2 gain=3
        M1 d g s b mf w=1u w=2u ic={gain},0 off
        .ends
        X1 d g 0 0 cell w=3u w=4u
        .end
        """
        let document = SPICESourceDocument(text: source, resolvedPath: "roles.sp", captureID: "captured-roles")
        let parsed = try await SPICEParser().parse(document: document, configuration: .default,
            fileResolver: NullFileResolver()).get()
        let model = try #require(parsed.models.first)
        #expect(model.parameterAssignments.map(\.name) == ["level", "version", "vth0", "vth0", "vtho"])
        #expect(model.parameterAssignments.map(\.value) == [.numeric(54), .string("4.8.1"), .numeric(0.4), .numeric(0.5), .numeric(0.6)])
        #expect(model.parameters["vth0"] == .numeric(0.5))
        #expect(model.parameterAssignments[3].location?.line == 3)
        #expect(model.parameterAssignments[3].origin?.location.line == 2)
        #expect(model.parameterAssignments[3].origin?.captureID == "captured-roles")
        let cell = try #require(parsed.subcircuits.first)
        #expect(cell.parameterAssignments.map(\.name) == ["w", "w"])
        #expect(cell.parameterAssignments.map(\.value) == [.numeric(1e-6), .numeric(2e-6)])
        #expect(cell.body.parameterDefinitions.map(\.value) == [.literal(2), .literal(3)])
        #expect(cell.body.parameterDefinitions.allSatisfy { $0.origin?.captureID == "captured-roles" })
        let mos = try #require(cell.body.components.first)
        #expect(mos.origin?.location.line == 6)
        #expect(mos.parameterAssignments.map(\.name) == ["w", "w", "ic", "off"])
        #expect(mos.parameterAssignments[2].value == .expression(.identifier("gain")))
        #expect(mos.parameterAssignments[2].additionalValues == [.numeric(0)])
        #expect(mos.parameterAssignments[3].value == .boolean(true))
        #expect(parsed.components.first?.parameterAssignments.map(\.value) == [.numeric(3e-6), .numeric(4e-6)])
    }

    @Test func nestedFunctionsStayOwnedByTheirLexicalBodies() async throws {
        let parsed = try await SPICEParser().parse(source: """
        function scopes
        .func shared(x) {x+1}
        .subckt outer a b
        .func shared(x) {x+2}
        .subckt inner a b
        .func shared(x) {x+3}
        R1 a b 100
        .ends
        Xchild a b inner
        .ends
        .subckt sibling a b
        R2 a b 200
        .ends
        .end
        """).get()
        let outer = try #require(parsed.subcircuits.first { $0.name == "outer" })
        let inner = try #require(outer.body.subcircuits.first)
        let sibling = try #require(parsed.subcircuits.first { $0.name == "sibling" })
        #expect(parsed.functionDefinitions.count == 1)
        #expect(outer.body.functionDefinitions.count == 1)
        #expect(inner.body.functionDefinitions.count == 1)
        #expect(sibling.body.functionDefinitions.isEmpty)
        #expect(parsed.controls.count == 1)
        #expect(outer.body.controls.count == 1)
        #expect(inner.body.controls.count == 1)
        #expect(sibling.body.controls.isEmpty)
        #expect(parsed.functionDefinitions[0].body == .binaryOperation(.add, .identifier("x"), .literal(1)))
        #expect(outer.body.functionDefinitions[0].body == .binaryOperation(.add, .identifier("x"), .literal(2)))
        #expect(inner.body.functionDefinitions[0].body == .binaryOperation(.add, .identifier("x"), .literal(3)))
        let roundTrip = try await SPICEParser().parse(source: SPICESerializer().serialize(parsed)).get()
        let restoredOuter = try #require(roundTrip.subcircuits.first { $0.name == "outer" })
        let restoredInner = try #require(restoredOuter.body.subcircuits.first)
        #expect(roundTrip.functionDefinitions.map(\.body) == parsed.functionDefinitions.map(\.body))
        #expect(restoredOuter.body.functionDefinitions.map(\.body) == outer.body.functionDefinitions.map(\.body))
        #expect(restoredInner.body.functionDefinitions.map(\.body) == inner.body.functionDefinitions.map(\.body))
        #expect(roundTrip.controls.count == 1)
        #expect(restoredOuter.body.controls.count == 1)
        #expect(restoredInner.body.controls.count == 1)
    }

    @Test func malformedBodyRestoresParentDeclarationsAndFunctions() async throws {
        let result = await SPICEParser().parse(source: """
        failure isolation
        .func parent(x) {x+1}
        .param outside=1
        .subckt broken a b
        .func leaked(x) {x+2}
        .param leaked=2
        Rinside a b 100
        Mbad a b 0 0 missing ic=1,2,3,4
        .ends
        Rafter a 0 200
        .end
        """, fileName: "broken.sp")
        #expect(!result.isSuccess)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
        let partial = try result.getAllowingErrors()
        #expect(partial.subcircuits.isEmpty)
        #expect(partial.components.map(\.name) == ["rafter"])
        #expect(partial.parameterDefinitions.map(\.name) == ["outside"])
        #expect(partial.functionDefinitions.map(\.name) == ["parent"])
        #expect(partial.controls.count == 1)
        #expect(result.errors.contains { $0.location?.file == "broken.sp" && $0.location?.line == 8 })
    }
}
