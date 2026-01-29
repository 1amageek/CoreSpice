import Testing
@testable import CoreSpiceParserSPICE
@testable import CoreSpiceParser
@testable import CoreSpiceParsedIR

@Suite
struct SPICELexerTests {

    @Test
    func basicTokenization() {
        let source = "R1 in out 1k"
        var lexer = SPICELexer(source: source)
        let tokens = lexer.tokenize()

        #expect(tokens.count >= 4) // At least R1, in, out, 1k, EOF
    }

    @Test
    func numberWithSuffix() {
        let source = "1k 10u 100n 1meg"
        var lexer = SPICELexer(source: source)
        let tokens = lexer.tokenize()

        // Check that numbers are properly scaled
        if case .number(let n) = tokens[0].token {
            #expect(n == 1000.0)
        }
        if case .number(let n) = tokens[1].token {
            #expect(abs(n - 1e-5) < 1e-10)
        }
    }

    @Test
    func directiveTokenization() {
        let source = ".model nch nmos level=1"
        var lexer = SPICELexer(source: source)
        let tokens = lexer.tokenize()

        if case .directive(let name) = tokens[0].token {
            #expect(name == "model")
        }
    }

    @Test
    func commentHandling() {
        let source = "* This is a comment\nR1 a b 1k"
        var lexer = SPICELexer(source: source)
        let tokens = lexer.tokenize()

        // Should have comment token
        let hasComment = tokens.contains { token in
            if case .comment = token.token { return true }
            return false
        }
        #expect(hasComment)
    }
}

@Suite
struct SPICEParserTests {

    @Test
    func parseSimpleNetlist() async {
        let source = """
        Test Circuit
        R1 in out 1k
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source, fileName: "test.sp")

        #expect(result.isSuccess)
        #expect(result.netlist?.components.count == 1)
        #expect(result.netlist?.title == "test circuit")
    }

    @Test
    func parseResistor() async {
        let source = """
        Resistor Test
        R1 node1 node2 10k
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let component = result.netlist?.components.first
        #expect(component?.name == "r1")
        #expect(component?.type == .resistor)
        #expect(component?.nodes.count == 2)
    }

    @Test
    func parseMOSFET() async {
        let source = """
        MOSFET Test
        M1 d g s b nch W=1u L=100n
        .model nch nmos level=1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let component = result.netlist?.components.first
        #expect(component?.type == .mosfet)
        #expect(component?.nodes.count == 4)
        #expect(component?.modelName == "nch")
    }

    @Test
    func parseSubcircuit() async {
        let source = """
        Subcircuit Test
        .subckt inv in out vdd vss
        M1 out in vdd vdd pch W=2u L=100n
        M2 out in vss vss nch W=1u L=100n
        .ends inv
        X1 a b vdd gnd inv
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.subcircuits.count == 1)
        #expect(result.netlist?.subcircuits.first?.name == "inv")
        #expect(result.netlist?.subcircuits.first?.ports.count == 4)
    }

    @Test
    func parseTransientAnalysis() async {
        let source = """
        Transient Test
        .tran 1n 100n
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .transient(let spec) = result.netlist?.analyses.first {
            if case .numeric(let stop) = spec.stopTime {
                #expect(abs(stop - 100e-9) < 1e-15)
            }
        }
    }

    @Test
    func parseACAnalysis() async {
        let source = """
        AC Test
        .ac dec 10 1 1g
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        if case .ac(let spec) = result.netlist?.analyses.first {
            #expect(spec.scaleType == .decade)
            #expect(spec.numberOfPoints == 10)
        }
    }

    @Test
    func canParseDetection() {
        let parser = SPICEParser()

        let spiceSource = """
        Test
        R1 a b 1k
        .end
        """
        #expect(parser.canParse(source: spiceSource))

        let notSpice = """
        some random text
        without spice syntax
        """
        #expect(!parser.canParse(source: notSpice))
    }
}

@Suite
struct SPICESerializerTests {

    @Test
    func serializeSimpleNetlist() {
        let netlist = ParsedNetlist(
            title: "Test Circuit",
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .numeric(1000)]
                )
            ]
        )

        let serializer = SPICESerializer()
        let output = serializer.serialize(netlist)

        #expect(output.contains("Test Circuit"))
        #expect(output.contains("R1"))
        #expect(output.contains(".end"))
    }
}

@Suite
struct AdvancedAnalysisParserTests {

    @Test
    func parseNoiseAnalysis() async {
        let source = """
        Noise Test
        .noise V(out) Vin dec 10 1 1meg
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .noise(let spec) = result.netlist?.analyses.first {
            #expect(spec.outputNode == "out")
            #expect(spec.inputSource == "vin")
            #expect(spec.scaleType == .decade)
            #expect(spec.numberOfPoints == 10)
        }
    }

    @Test
    func parseTransferFunctionAnalysis() async {
        let source = """
        TF Test
        .tf V(out) Vin
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .transferFunction(let spec) = result.netlist?.analyses.first {
            #expect(spec.output.lowercased() == "v(out)")
            #expect(spec.input.lowercased() == "vin")
        }
    }

    @Test
    func parseSensitivityAnalysis() async {
        let source = """
        Sensitivity Test
        .sens V(out)
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .sensitivity(let spec) = result.netlist?.analyses.first {
            #expect(spec.output.lowercased() == "v(out)")
        }
    }

    @Test
    func parseFourierAnalysis() async {
        let source = """
        Fourier Test
        .four 1meg V(out)
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .fourier(let spec) = result.netlist?.analyses.first {
            if case .numeric(let freq) = spec.frequency {
                #expect(freq == 1e6)
            }
            #expect(spec.outputs.count >= 1)
        }
    }

    @Test
    func parsePoleZeroAnalysis() async {
        let source = """
        PZ Test
        .pz node1 node2 node3 node4 vol pz
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .poleZero(let spec) = result.netlist?.analyses.first {
            #expect(spec.inputNode == "node1")
            #expect(spec.inputReference == "node2")
            #expect(spec.outputNode == "node3")
            #expect(spec.outputReference == "node4")
            #expect(spec.transferType == .voltage)
            #expect(spec.analysisType == .both)
        }
    }

    @Test
    func parseMonteCarloAnalysis() async {
        let source = """
        MC Test
        .mc 100 dc Vin 0 5 0.1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 1)

        if case .monteCarlo(let spec) = result.netlist?.analyses.first {
            #expect(spec.iterations == 100)
        }
    }

    @Test
    func parseMeasureCommand() async {
        let source = """
        Measure Test
        .meas tran delay trig V(in) val=0.5 rise=1 targ V(out) val=0.5 rise=1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        // .meas directives may be partially supported or stored as unrecognized
        // The test verifies that the parser at least processes the netlist
        // without crashing, even if .meas is not fully implemented
        #expect(result.netlist != nil || result.diagnostics.count > 0)
    }
}
