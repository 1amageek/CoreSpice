import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("SPICE card symbol roles", .timeLimit(.minutes(1)))
struct CardSymbolParserTests {
    // These X statements are verbatim original Sky130 library lines 5939 and 3630.
    static let originalLines = """
    Original source symbols
    .subckt sky130_fd_sc_hd__dfxtp_1 CLK D VGND VNB VPB VPWR Q
    X0 a_891_413# a_193_47# a_975_413# VPB sky130_fd_pr__pfet_01v8_hvt w=420000u l=150000u
    X1 VGND a_27_47# X VNB sky130_fd_pr__nfet_01v8 w=520000u l=150000u
    .ends sky130_fd_sc_hd__dfxtp_1
    .end
    """

    @Test func originalSky130InternalNodesDoNotBecomeModelReferences() async throws {
        let result = try await parse(Self.originalLines)
        let body = try #require(result.subcircuits.first?.body)
        #expect(body.components[0].nodes.map(\.name) == ["a_891_413#", "a_193_47#", "a_975_413#", "vpb"])
        #expect(body.components[0].modelName == "sky130_fd_pr__pfet_01v8_hvt")
        #expect(body.components[1].nodes.map(\.name) == ["vgnd", "a_27_47#", "x", "vnb"])
        #expect(body.components[1].modelName == "sky130_fd_pr__nfet_01v8")
        #expect(body.components[0].parameters["w"] == .numeric(0.42))
        #expect(body.components[0].parameters["l"] == .numeric(0.15))
    }

    @Test func namesPortsModelReferencesAndOutputReferencesKeepPhysicalSymbols() async throws {
        let result = try await parse("""
        Physical symbols
        .model model-0/branch# D is=1p
        .subckt cell-0/CLK# cts_net-4_cell-0/CLK:A port-0-0
        Ddevice-0/branch# cts_net-4_cell-0/CLK:A port-0-0 model-0/branch#
        .ends cell-0/CLK#
        Xcell-0/CLK# cell-0:CLK port-0-0 cell-0/CLK#
        Rcts-0/branch# cell-0:CLK cts_net-4_cell-0/CLK:A 1k
        .save v(cts_net-4_cell-0/CLK:A) i(Rcts-0/branch#)
        .print tran v(cell-0:CLK) i(Rcts-0/branch#)
        .end
        """)
        #expect(result.models.first?.name == "model-0/branch#")
        let cell = try #require(result.subcircuits.first)
        #expect(cell.name == "cell-0/clk#")
        #expect(cell.ports == ["cts_net-4_cell-0/clk:a", "port-0-0"])
        #expect(cell.body.components.first?.name == "ddevice-0/branch#")
        #expect(cell.body.components.first?.modelName == "model-0/branch#")
        #expect(result.components[0].name == "xcell-0/clk#")
        #expect(result.components[0].modelName == "cell-0/clk#")
        #expect(result.components[1].nodes.map(\.name) == ["cell-0:clk", "cts_net-4_cell-0/clk:a"])
        #expect(result.components[1].parameters["r"] == .numeric(1000))
    }

    @Test(arguments: [true, false]) func casePolicyIsUnchanged(caseInsensitive: Bool) async throws {
        let result = try await parse("Physical case\nXCell-0/CLK# Node-A/B# 0 Model-A/B#\n.end\n",
            configuration: .init(caseInsensitive: caseInsensitive))
        let element = try #require(result.components.first)
        #expect(element.name == (caseInsensitive ? "xcell-0/clk#" : "XCell-0/CLK#"))
        #expect(element.nodes.first?.name == (caseInsensitive ? "node-a/b#" : "Node-A/B#"))
        #expect(element.modelName == (caseInsensitive ? "model-a/b#" : "Model-A/B#"))
    }

    @Test func controllingSourceAndSwitchModelCountAsPhysicalFields() async throws {
        let result = try await parse("""
        Controlled physical names
        Vcontrol-0/branch# sense-0/branch# 0 0
        F1 out 0 Vcontrol-0/branch# 2
        W1 vdd out Vcontrol-0/branch# switch-0/branch#
        .model switch-0/branch# CSW ron=1 roff=1meg
        .end
        """)
        #expect(result.components[1].nodes.count == 2)
        #expect(result.components[1].parameters["control_source"] == .string("vcontrol-0/branch#"))
        #expect(result.components[1].parameters["f"] == .numeric(2))
        #expect(result.components[2].nodes.count == 2)
        #expect(result.components[2].parameters["control_source"] == .string("vcontrol-0/branch#"))
        #expect(result.components[2].modelName == "switch-0/branch#")
    }

    @Test(arguments: ["F1 out 0 VCTRL 1e+3", "H1 out 0 VCTRL 1e+3", "R1 1e+3 0 1k"])
    func numericExponentPlusKeepsItsOriginalTokenMeaning(card: String) async throws {
        let result = try await parse("Numeric token extent\n\(card)\n.end\n")
        let element = try #require(result.components.first)
        if card.hasPrefix("R") {
            #expect(element.nodes.map(\.name) == ["1000", "0"])
            #expect(element.parameters["r"] == .numeric(1000))
        } else {
            #expect(element.nodes.map(\.name) == ["out", "0"])
            #expect(element.parameters["control_source"] == .string("vctrl"))
            #expect(element.parameters[card.hasPrefix("F") ? "f" : "h"] == .numeric(1000))
        }
    }

    @Test(arguments: [false, true]) func paramsPrefixIsAnEntirePhysicalSymbol(port: Bool) async throws {
        let body = port
            ? ".subckt cell params-0 params/branch#\n.ends cell"
            : "X1 params-0 params/branch# cell"
        let result = try await parse("Complete keyword boundary\n\(body)\n.end\n")
        if port {
            #expect(result.subcircuits.first?.ports == ["params-0", "params/branch#"])
        } else {
            #expect(result.components.first?.nodes.map(\.name) == ["params-0", "params/branch#"])
            #expect(result.components.first?.modelName == "cell")
        }
    }

    @Test func subtractionDivisionConditionalSuffixAndCommentsRetainTheirRoles() async throws {
        let result = try await parse("""
        Operator roles
        .param mix={a-b/c} choose={q?a-b:c/d}
        Xfirst n-a/b# 0 model-a/b# params : p={a-b/c} $ unchanged inline comment
        * unchanged full line comment
        + gain={q?a-b:c/d}
        R1 n-a/b# 0 1meg
        .end
        """)
        let subtraction = ParsedExpression.binaryOperation(.subtract, .identifier("a"),
            .binaryOperation(.divide, .identifier("b"), .identifier("c")))
        #expect(result.parameters["mix"] == subtraction)
        #expect(result.components[0].parameters["p"] == .expression(subtraction))
        #expect(result.components[0].parameters["gain"] == .expression(.conditional(
            condition: .identifier("q"), then: .binaryOperation(.subtract, .identifier("a"), .identifier("b")),
            else: .binaryOperation(.divide, .identifier("c"), .identifier("d")))))
        #expect(result.components[1].parameters["r"] == .numeric(1e6))
    }

    @Test func malformedXAssignmentTailHasLocatedFailure() async {
        let result = await SPICEParser().parse(document: .init(text:
            "Bad X tail\nX1 a-0/b# 0 model-a/b# p=1 @\n.end\n", resolvedPath: "bad-symbols.sp"),
            configuration: .default, fileResolver: NullFileResolver())
        #expect(!result.isSuccess)
        #expect(result.errors.first?.location?.file == "bad-symbols.sp")
        #expect(result.errors.first?.location?.line == 2)
        #expect(result.errors.first?.location?.column == 28)
    }

    private func parse(_ text: String, configuration: ParserConfiguration = .default) async throws -> ParsedNetlist {
        try await SPICEParser().parse(document: .init(text: text, resolvedPath: "symbols.sp"),
            configuration: configuration, fileResolver: NullFileResolver()).get()
    }
}
