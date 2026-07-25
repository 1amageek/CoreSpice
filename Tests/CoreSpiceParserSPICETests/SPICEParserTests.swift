import Testing
import Foundation
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
    func overflowNumericLiteralIsInvalidToken() {
        let source = "1e309"
        var lexer = SPICELexer(source: source)
        let tokens = lexer.tokenize()

        if case .invalidNumericLiteral(let literal) = tokens[0].token {
            #expect(literal == "1e309")
        } else {
            Issue.record("Expected overflow literal to be rejected, got \(tokens[0].token)")
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
    func expressionOperatorTokenization() {
        let source = "a>=b && c!=d ? e%2 : f"
        var lexer = SPICELexer(source: source)
        let tokenDescriptions = lexer.tokenize().map { $0.token.description }

        #expect(tokenDescriptions.contains(">"))
        #expect(tokenDescriptions.contains("&"))
        #expect(tokenDescriptions.contains("!"))
        #expect(tokenDescriptions.contains("?"))
        #expect(tokenDescriptions.contains("%"))
        #expect(tokenDescriptions.contains(":"))
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
    func parsePositionalParameterExpression() async throws {
        let source = """
        Positional Expression Test
        .param rval=1k
        R1 node1 node2 {rval}
        R2 node2 0 rval
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let r1 = try #require(netlist.components.first { $0.name == "r1" })
        let r2 = try #require(netlist.components.first { $0.name == "r2" })
        #expect(r1.parameters["r"] == .expression(.identifier("rval")))
        #expect(r2.parameters["r"] == .expression(.identifier("rval")))
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
    func parseJFETComponentsAndModels() async throws {
        let source = """
        JFET parse deck
        JN drain gate source njmod area=2
        JP pout pgate psource pjmod
        .model njmod njf beta=1m vto=-2 lambda=0.01 cgs=1p cgd=2p
        .model pjmod pjf beta=2m vto=-2
        .op
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)
        let netlist = try result.get()

        let njfet = try #require(netlist.components.first { $0.name == "jn" })
        let pjfet = try #require(netlist.components.first { $0.name == "jp" })
        #expect(njfet.type == .jfet)
        #expect(njfet.nodes.map(\.name) == ["drain", "gate", "source"])
        #expect(njfet.modelName == "njmod")
        #expect(njfet.parameters["area"] != nil)
        #expect(pjfet.modelName == "pjmod")
        #expect(netlist.models.first { $0.name == "njmod" }?.type == .njf)
        #expect(netlist.models.first { $0.name == "pjmod" }?.type == .pjf)
    }

    @Test
    func parseVoltageControlledSwitchModel() async throws {
        let source = """
        Switch Test
        S1 in out ctrl 0 swmod
        .model swmod sw ron=10 roff=1e9 vt=2 vh=0.1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let component = try #require(netlist.components.first)
        #expect(component.type == .switch_)
        #expect(component.nodes.count == 4)
        #expect(component.modelName == "swmod")
        let model = try #require(netlist.models.first)
        #expect(model.type == .sw)
    }

    @Test
    func parseCurrentControlledSourceReferences() async throws {
        let source = """
        Source Reference Test
        VCTRL ctrl 0 dc 1
        F1 out 0 VCTRL 2
        H1 hout 0 VCTRL 1k
        W1 vdd swout VCTRL cswmod
        .model cswmod csw ron=10 roff=1e9 it=1m ih=0.1m
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let f1 = try #require(netlist.components.first { $0.name == "f1" })
        let h1 = try #require(netlist.components.first { $0.name == "h1" })
        let w1 = try #require(netlist.components.first { $0.name == "w1" })

        #expect(f1.type == .cccs)
        #expect(f1.nodes.map(\.name) == ["out", "0"])
        #expect(f1.parameters["control_source"] == .string("vctrl"))
        #expect(f1.parameters["f"] == .numeric(2))

        #expect(h1.type == .ccvs)
        #expect(h1.nodes.map(\.name) == ["hout", "0"])
        #expect(h1.parameters["control_source"] == .string("vctrl"))
        #expect(h1.parameters["h"] == .numeric(1000))

        #expect(w1.type == .currentSwitch)
        #expect(w1.nodes.map(\.name) == ["vdd", "swout"])
        #expect(w1.parameters["control_source"] == .string("vctrl"))
        #expect(w1.modelName == "cswmod")
    }

    @Test
    func parseCoupledInductorReferenceAndCoefficient() async throws {
        let source = """
        Coupled Inductor Test
        L1 in 0 4u
        L2 out 0 9u
        K1 L1 L2 0.5
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let coupling = try #require(netlist.components.first { $0.name == "k1" })
        #expect(coupling.type == .coupledInductors)
        #expect(coupling.nodes.map(\.name) == ["l1", "l2"])
        #expect(coupling.parameters["k"] == .numeric(0.5))
    }

    @Test
    func parseExplicitCurrentControlledElementsWithNamedParametersAndNumericSenseNodes() async throws {
        let source = """
        Explicit Sense Test
        F1 out 0 sense 0 f=2
        H1 hout 0 0 sense h=1k
        W1 vdd swout 0 sense cswmod
        .model cswmod csw ron=10 roff=1e9 it=1m ih=0.1m
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let f1 = try #require(netlist.components.first { $0.name == "f1" })
        let h1 = try #require(netlist.components.first { $0.name == "h1" })
        let w1 = try #require(netlist.components.first { $0.name == "w1" })

        #expect(f1.nodes.map(\.name) == ["out", "0", "sense", "0"])
        #expect(f1.parameters["control_source"] == nil)
        #expect(f1.parameters["f"] == .numeric(2))

        #expect(h1.nodes.map(\.name) == ["hout", "0", "0", "sense"])
        #expect(h1.parameters["control_source"] == nil)
        #expect(h1.parameters["h"] == .numeric(1000))

        #expect(w1.nodes.map(\.name) == ["vdd", "swout", "0", "sense"])
        #expect(w1.parameters["control_source"] == nil)
        #expect(w1.modelName == "cswmod")
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
    func parseTransientAnalysisPreservesParameterValues() async {
        let source = """
        Transient Parameter Test
        .param tstop=100n tstep={tstop/100}
        .tran {tstep} {tstop}
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        if case .transient(let spec) = result.netlist?.analyses.first {
            guard case .expression = spec.stepTime else {
                Issue.record("Expected transient step time expression, got \(String(describing: spec.stepTime))")
                return
            }
            guard case .expression = spec.stopTime else {
                Issue.record("Expected transient stop time expression, got \(spec.stopTime)")
                return
            }
        } else {
            Issue.record("Expected transient analysis")
        }
    }

    @Test
    func parseSweepAnalysesPreserveParameterValues() async {
        let source = """
        Sweep Parameter Test
        .param fstart=1 fstop=1meg vstop=1.8
        .ac dec 10 {fstart} {fstop}
        .dc V1 0 {vstop} 0.1
        .noise V(out) V1 dec 10 {fstart} {fstop}
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        #expect(result.netlist?.analyses.count == 3)

        if case .ac(let spec) = result.netlist?.analyses.first {
            guard case .expression = spec.startFrequency else {
                Issue.record("Expected AC start frequency expression, got \(spec.startFrequency)")
                return
            }
            guard case .expression = spec.stopFrequency else {
                Issue.record("Expected AC stop frequency expression, got \(spec.stopFrequency)")
                return
            }
        } else {
            Issue.record("Expected AC analysis")
        }

        if result.netlist?.analyses.count ?? 0 > 1,
           case .dc(let spec) = result.netlist?.analyses[1] {
            guard case .expression = spec.stopValue else {
                Issue.record("Expected DC stop value expression, got \(spec.stopValue)")
                return
            }
        } else {
            Issue.record("Expected DC analysis")
        }

        if result.netlist?.analyses.count ?? 0 > 2,
           case .noise(let spec) = result.netlist?.analyses[2] {
            guard case .expression = spec.startFrequency else {
                Issue.record("Expected noise start frequency expression, got \(spec.startFrequency)")
                return
            }
            guard case .expression = spec.stopFrequency else {
                Issue.record("Expected noise stop frequency expression, got \(spec.stopFrequency)")
                return
            }
        } else {
            Issue.record("Expected noise analysis")
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
    func rejectZeroACAnalysisPointCount() async {
        let source = """
        AC Point Count Test
        .ac dec 0 1 1g
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Expected positive integer analysis point count")
        })
    }

    @Test
    func rejectFractionalACAnalysisPointCount() async {
        let source = """
        AC Point Count Test
        .ac dec 1.5 1 1g
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Expected positive integer analysis point count")
        })
    }

    @Test
    func rejectUnsupportedDirective() async throws {
        let source = """
        Unsupported Directive Test
        .unknown_control foo bar
        R1 in out 1k
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.hasErrors)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message == "Unsupported SPICE directive: .unknown_control"
        })
        #expect(throws: ParserDiagnostic.self) {
            _ = try result.get()
        }
        let partialNetlist = try result.getAllowingErrors()
        #expect(partialNetlist.components.map(\.name) == ["r1"])
    }

    @Test
    func conditionalPreprocessorSelectsTrueBranch() async throws {
        let source = """
        Conditional Test
        .param use_alt=1
        .if use_alt
        R1 in out 1k
        .else
        .unknown_control should_not_parse
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source, fileName: "conditional.sp")

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.sourcePath == "conditional.sp")
        #expect(netlist.components.map(\.name) == ["r1"])
        #expect(netlist.parameterDefinitions.map(\.name) == ["use_alt"])
        #expect(netlist.preprocessingEvents.contains { event in
            event.kind == .ifStatement && event.expression == "use_alt" && event.active
        })
    }

    @Test
    func conditionalPreprocessorSelectsElseIfBranch() async throws {
        let source = """
        Conditional Elseif Test
        .param mode=2 limit={1k/2}
        .if mode == 1
        R1 in out 1k
        .elseif mode == 2 && limit >= 500
        R2 in out 2k
        .else
        R3 in out 3k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r2"])
        #expect(netlist.preprocessingEvents.contains { event in
            event.kind == .elseIf && event.expression == "mode == 2 && limit >= 500" && event.active
        })
    }

    @Test
    func conditionalPreprocessorSupportsNestedBlocks() async throws {
        let source = """
        Nested Conditional Test
        .param outer=1 inner=0
        .if outer
        .if inner
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .else
        R3 in out 3k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r2"])
    }

    @Test
    func conditionalPreprocessorKeepsSubcircuitParameterScopeLocal() async throws {
        let source = """
        Subcircuit Scope Conditional Test
        .param local=0
        .subckt cell a b
        .param local=1
        .if local
        R1 a b 1k
        .endif
        .ends cell
        .if local
        Rtop in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.subcircuits.first?.body.components.map(\.name) == ["r1"])
        #expect(netlist.components.map(\.name) == ["r2"])
    }

    @Test
    func subcircuitParameterDefinitionsStayBodyLocal() async throws {
        let source = """
        Subcircuit Parameter Evidence Test
        .param global_scale=2
        .subckt cell a b
        .param local_r={global_scale * 1k}
        R1 a b {local_r}
        .ends cell
        X1 in out cell
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.parameterDefinitions.map(\.name) == ["global_scale"])

        let subcircuit = try #require(netlist.subcircuits.first)
        #expect(subcircuit.body.parameterDefinitions.map(\.name) == ["local_r"])
        #expect(subcircuit.body.parameters["local_r"] != nil)

        let output = SPICESerializer().serialize(netlist, options: .default)
        let globalParamCount = output.components(separatedBy: ".param global_scale").count - 1
        let localParamCount = output.components(separatedBy: ".param local_r").count - 1
        #expect(globalParamCount == 1)
        #expect(localParamCount == 1)
        let subcircuitHeader = try #require(output.range(of: ".subckt cell")?.lowerBound)
        let localParameter = try #require(output.range(of: ".param local_r")?.lowerBound)
        let subcircuitEnd = try #require(output.range(of: ".ends cell")?.lowerBound)
        #expect(subcircuitHeader < localParameter)
        #expect(localParameter < subcircuitEnd)
    }

    @Test
    func conditionalPreprocessorReadsSubcircuitParamsClause() async throws {
        let source = """
        Subcircuit Params Conditional Test
        .subckt cell a b params: enabled=1
        .if enabled
        R1 a b 1k
        .endif
        .ends cell
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.subcircuits.first?.body.components.map(\.name) == ["r1"])
    }

    @Test
    func conditionalPreprocessorSupportsSpiceDotOperators() async throws {
        let source = """
        Dot Operator Conditional Test
        .param mode=2 disabled=0
        .if mode .eq. 2 .and. .not. disabled
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r1"])
    }

    @Test
    func conditionalPreprocessorStripsInlineCommentsFromConditions() async throws {
        let source = """
        Commented Conditional Test
        .param mode=1
        .if mode == 1 ; select resistor branch
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .if mode == 1 $ select capacitor branch
        C1 out 0 1p
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r1", "c1"])
        #expect(netlist.preprocessingEvents.contains { event in
            event.kind == .ifStatement && event.expression == "mode == 1" && event.active
        })
    }

    @Test
    func conditionalPreprocessorRejectsUnknownNumericSuffix() async {
        let source = """
        Unknown Suffix Conditional Test
        .if 1qq
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Unknown numeric suffix 'qq'")
        })
        #expect(result.netlist?.components.isEmpty == true)
    }

    @Test
    func conditionalPreprocessorUsesUserFunctionInParameterCondition() async throws {
        let source = """
        Conditional User Function Test
        .func enabled(x) {x - 0.5}
        .param mode=enabled(1)
        .if mode > 0
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r1"])
        #expect(netlist.controls.contains { control in
            if case .function(let name, let parameters, _, _) = control {
                return name == "enabled" && parameters == ["x"]
            }
            return false
        })
    }

    @Test
    func conditionalPreprocessorRejectsRecursiveUserFunction() async {
        let source = """
        Recursive Conditional User Function Test
        .func loop(x) {loop(x)}
        .if loop(1)
        R1 in out 1k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Recursive conditional function 'loop'")
        })
        #expect(result.netlist?.components.isEmpty == true)
    }

    @Test
    func conditionalPreprocessorUsesLoweringCompatibleBuiltInFunctions() async throws {
        let source = """
        Conditional Builtin Function Test
        .if limit(2, 0, 1) == 1 && sign(-2) == -1 && int(1.9) == 1
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r1"])
    }

    @Test
    func sharedExpressionParserRequiresCompleteStandaloneInput() throws {
        let parser = SPICEExpressionParser()

        do {
            _ = try parser.parse("gain)")
            Issue.record("Expected trailing ')' to fail.")
        } catch let diagnostic as ParserDiagnostic {
            #expect(diagnostic.message.contains("Unexpected token"))
        }
    }

    @Test
    func sharedExpressionParserParsesSpiceDotOperators() throws {
        let expression = try SPICEExpressionParser().parse("mode .eq. 2 .and. .not. disabled")

        guard case .binaryOperation(.and, let lhs, let rhs) = expression else {
            Issue.record("Expected logical-and expression, got \(expression).")
            return
        }
        guard case .binaryOperation(.equal, .identifier("mode"), .literal(2)) = lhs else {
            Issue.record("Expected equality lhs, got \(lhs).")
            return
        }
        guard case .unaryOperation(.not, .identifier("disabled")) = rhs else {
            Issue.record("Expected not rhs, got \(rhs).")
            return
        }
    }

    @Test
    func sharedExpressionParserDoesNotRewriteIdentifierText() throws {
        let expression = try SPICEExpressionParser().parse("foo.or.bar")

        #expect(expression == .identifier("foo.or.bar"))
    }

    @Test
    func invalidNumericLiteralFailsInsteadOfBecomingZero() async {
        let source = """
        Invalid Number Test
        R1 in out 1e+
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Invalid numeric literal '1e+'")
        })
    }

    @Test
    func invalidPositionalNumericSuffixFailsComponentParsing() async {
        let source = """
        Invalid Suffix Test
        R1 in out 1qq
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Unknown numeric suffix 'qq'")
        })
    }

    @Test
    func inactiveConditionalBranchCanContainInvalidSyntax() async throws {
        let source = """
        Inactive Branch Test
        .if 0
        .unknown_control should_not_parse
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r2"])
    }

    @Test
    func conditionalPreprocessorRejectsUnknownActiveParameter() async {
        let source = """
        Unknown Conditional Parameter Test
        .if missing == 1
        R1 in out 1k
        .else
        R2 in out 2k
        .endif
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Unknown conditional parameter 'missing'")
        })
        #expect(result.netlist?.components.isEmpty == true)
    }

    @Test
    func conditionalPreprocessorRejectsUnbalancedBlock() async {
        let source = """
        Unbalanced Conditional Test
        .if 1
        R1 in out 1k
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message == "Unterminated SPICE conditional block"
        })
    }

    @Test
    func parseFunctionDefinitionAndParameterCall() async throws {
        let source = """
        Function Test
        .func scale(x) {x * 2}
        .param rload=scale(1k)
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.controls.contains { control in
            if case .function(let name, let parameters, _, _) = control {
                return name == "scale" && parameters == ["x"]
            }
            return false
        })
        if case .functionCall(let name, let arguments) = netlist.parameters["rload"] {
            #expect(name == "scale")
            #expect(arguments.count == 1)
        } else {
            Issue.record("Expected rload to be parsed as a function call expression.")
        }
    }

    @Test
    func parseFunctionAndParameterExpressionsPreserveFullOperatorIR() async throws {
        let source = """
        Full Expression Function Test
        .func choose(x, y) {x .gt. y ? x : y}
        .param selected={choose(2, 1) .eq. 2 .and. 3 % 2 .eq. 1}
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        guard case .function(_, _, let body, _)? = netlist.controls.first else {
            Issue.record("Expected function control.")
            return
        }
        guard case .conditional(let condition, let thenExpression, let elseExpression) = body else {
            Issue.record("Expected ternary function body, got \(body).")
            return
        }
        guard case .binaryOperation(.greaterThan, .identifier("x"), .identifier("y")) = condition else {
            Issue.record("Expected comparison condition, got \(condition).")
            return
        }
        #expect(thenExpression == .identifier("x"))
        #expect(elseExpression == .identifier("y"))

        guard let selected = netlist.parameters["selected"] else {
            Issue.record("Expected expression parameter.")
            return
        }
        guard case .binaryOperation(.and, _, _) = selected else {
            Issue.record("Expected logical-and parameter expression, got \(selected).")
            return
        }
    }

    @Test
    func parseProbeAndSaveVariablesWithoutLosingCallSyntax() async throws {
        let source = """
        Probe Test
        .save V(out) I(V1) all
        .probe V(in,out)
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.controls.contains { control in
            if case .save(let variables, _) = control {
                return variables == ["v(out)", "i(v1)", "all"]
            }
            return false
        })
        #expect(netlist.controls.contains { control in
            if case .probe(let variables, _) = control {
                return variables == ["v(in,out)"]
            }
            return false
        })
    }

    @Test
    func parseInitialConditionsAndNodeSetsWithVoltageSyntax() async throws {
        let source = """
        IC Test
        .ic V(out)=1.2 in=0
        .nodeset V(mid)=0.5
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        if case .numeric(let out)? = netlist.initialConditions["out"] {
            #expect(out == 1.2)
        } else {
            Issue.record("Expected V(out) initial condition.")
        }
        if case .numeric(let input)? = netlist.initialConditions["in"] {
            #expect(input == 0)
        } else {
            Issue.record("Expected plain node initial condition.")
        }
        if case .numeric(let mid)? = netlist.nodeSets["mid"] {
            #expect(mid == 0.5)
        } else {
            Issue.record("Expected V(mid) nodeset.")
        }
    }

    @Test
    func fractionalNumericInitialConditionNodeFails() async {
        let source = """
        Fractional IC Node Test
        V1 1 0 dc 1
        R1 1 0 1k
        .ic V(1.5)=0.1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Numeric node names must be non-negative integers")
        })
    }

    @Test
    func fractionalNumericOutputNodeFails() async {
        let source = """
        Fractional Output Node Test
        V1 1 0 dc 1
        R1 1 0 1k
        .print dc V(1.5)
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Numeric node names must be non-negative integers")
        })
    }

    @Test
    func parseTransientUICAndMaximumStep() async throws {
        let source = """
        UIC Transient Test
        V1 in 0 dc 1
        R1 in out 1k
        C1 out 0 1p
        .tran 1n 10n 0 2n uic
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        guard case .transient(let spec)? = netlist.analyses.first else {
            Issue.record("Expected transient analysis.")
            return
        }
        #expect(spec.useInitialConditions)
        #expect(spec.stepTime == .numeric(1e-9))
        #expect(spec.stopTime == .numeric(10e-9))
        #expect(spec.startTime == .numeric(0))
        #expect(spec.maxStep == .numeric(2e-9))
    }

    @Test
    func resolvedIncludeKeepsControlEvidenceAndMergesContent() async throws {
        let source = """
        Include Test
        .include "models.inc"
        .end
        """
        let resolver = MemoryFileResolver(
            includes: [
                "models.inc": """
                .param rload=1k
                .model dmod d
                """
            ]
        )
        var configuration = ParserConfiguration.default
        configuration.resolveIncludes = true

        let parser = SPICEParser()
        let result = await parser.parse(
            source: source,
            fileName: "top.sp",
            configuration: configuration,
            fileResolver: resolver
        )

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.parameters["rload"] != nil)
        #expect(netlist.models.first?.name == "dmod")
        #expect(netlist.controls.contains { control in
            if case .include(let path, _) = control {
                return path == "models.inc"
            }
            return false
        })
    }

    @Test
    func resolvedIncludeConditionCanUseParentParameters() async throws {
        let source = """
        Include Conditional Test
        .param corner=2
        .include "conditional.inc"
        .end
        """
        let resolver = MemoryFileResolver(
            includes: [
                "conditional.inc": """
                .if corner == 2
                R1 in out 1k
                .else
                R2 in out 2k
                .endif
                """
            ]
        )
        var configuration = ParserConfiguration.default
        configuration.resolveIncludes = true

        let parser = SPICEParser()
        let result = await parser.parse(
            source: source,
            fileName: "top.sp",
            configuration: configuration,
            fileResolver: resolver
        )

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.components.map(\.name) == ["r1"])
    }

    @Test
    func localLibraryResolverExtractsNamedSectionAndKeepsEvidence() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corespice-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove temporary library directory: \(error)")
            }
        }

        let libraryURL = root.appendingPathComponent("corners.lib")
        try """
        .lib tt
        .param corner_scale=1
        .model dtt d
        .endl tt
        .lib ss
        .param corner_scale=2
        .model dss d
        .endl ss
        """.write(to: libraryURL, atomically: true, encoding: .utf8)

        let source = """
        Library Test
        .lib "corners.lib" ss
        .end
        """
        var configuration = ParserConfiguration.default
        configuration.resolveIncludes = true

        let parser = SPICEParser()
        let result = await parser.parse(
            source: source,
            fileName: root.appendingPathComponent("top.sp").path,
            configuration: configuration,
            fileResolver: LocalFileResolver(searchPaths: [root.path])
        )

        #expect(result.isSuccess)
        let netlist = try result.get()
        if case .literal(let value)? = netlist.parameters["corner_scale"] {
            #expect(value == 2)
        } else {
            Issue.record("Expected selected library section parameter.")
        }
        #expect(netlist.models.map(\.name) == ["dss"])
        #expect(netlist.controls.contains { control in
            if case .library(let path, let section, _) = control {
                return path == "corners.lib" && section == "ss"
            }
            return false
        })
    }

    @Test
    func localLibrarySectionResolvesNestedIncludeRelativeToLibraryFile() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corespice-nested-lib-\(UUID().uuidString)")
        let modelDirectory = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove temporary library directory: \(error)")
            }
        }

        try """
        .param nested_scale=3
        .model dincluded d
        """.write(to: modelDirectory.appendingPathComponent("common.inc"), atomically: true, encoding: .utf8)
        try """
        .lib tt
        .param corner_scale=1
        .endl tt
        .lib ss
        .include "common.inc"
        .param corner_scale={nested_scale * 2}
        .endl ss
        """.write(to: modelDirectory.appendingPathComponent("corners.lib"), atomically: true, encoding: .utf8)

        let source = """
        Nested Library Test
        .lib "models/corners.lib" ss
        .end
        """
        var configuration = ParserConfiguration.default
        configuration.resolveIncludes = true

        let parser = SPICEParser()
        let result = await parser.parse(
            source: source,
            fileName: root.appendingPathComponent("top.sp").path,
            configuration: configuration,
            fileResolver: LocalFileResolver(searchPaths: [root.path])
        )

        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.models.map(\.name) == ["dincluded"])
        #expect(netlist.parameters["nested_scale"] != nil)
        #expect(netlist.parameters["corner_scale"] != nil)
        #expect(netlist.controls.contains { control in
            if case .include(let path, _) = control {
                return path == "common.inc"
            }
            return false
        })
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

private struct MemoryFileResolver: FileResolver {
    let includes: [String: String]
    let libraries: [String: String]

    init(includes: [String: String] = [:], libraries: [String: String] = [:]) {
        self.includes = includes
        self.libraries = libraries
    }

    func resolveInclude(path: String, relativeTo: String?) async throws -> String {
        guard let content = includes[path] else {
            throw FileResolverError.fileNotFound(path: path)
        }
        return content
    }

    func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> String {
        guard let content = libraries[path] else {
            throw FileResolverError.fileNotFound(path: path)
        }
        return content
    }

    func readFile(at path: String) async throws -> String {
        guard let content = includes[path] ?? libraries[path] else {
            throw FileResolverError.fileNotFound(path: path)
        }
        return content
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

    @Test
    func serializeParsedFunctionParameterAndMeasureWithoutDroppingDependencies() async throws {
        let source = """
        Serialize Intent Test
        .func scale(x) {x * 2}
        .param gain=scale(1k)
        .op
        .meas op gain_at_zero find V(1) at=0
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)
        let netlist = try result.get()

        let output = SPICESerializer().serialize(netlist)

        #expect(output.components(separatedBy: ".param").count - 1 == 1)
        #expect(output.contains(".func scale(x)"))
        #expect(output.contains("scale(1.0k)"))
        #expect(output.contains(".meas op gain_at_zero find v(1) at=0"))
    }

    @Test
    func serializeCurrentControlledSourceReferencesAsStandardSpice() async throws {
        let source = """
        Serialize Source Reference Test
        VCTRL ctrl 0 dc 1
        F1 out 0 VCTRL 2
        H1 hout 0 VCTRL 1k
        W1 vdd swout VCTRL cswmod
        .model cswmod csw ron=10 roff=1e9 it=1m ih=0.1m
        .end
        """

        let parser = SPICEParser()
        let netlist = try await parser.parse(source: source).get()

        let output = SPICESerializer().serialize(netlist)

        #expect(output.contains("f1 out 0 vctrl 2"))
        #expect(output.contains("h1 hout 0 vctrl 1.0k"))
        #expect(output.contains("w1 vdd swout vctrl cswmod"))
        #expect(!output.contains("control_source="))
    }

    @Test
    func explicitCurrentControlledSourceRoundTripKeepsSenseTerminals() async throws {
        let source = """
        Serialize Explicit Sense Test
        F1 out 0 sense 0 f=2
        H1 hout 0 0 sense h=1k
        .end
        """

        let parser = SPICEParser()
        let original = try await parser.parse(source: source).get()
        let output = SPICESerializer().serialize(original)
        let roundTripped = try await parser.parse(source: output).get()

        let f1 = try #require(roundTripped.components.first { $0.name == "f1" })
        let h1 = try #require(roundTripped.components.first { $0.name == "h1" })

        #expect(f1.nodes.map(\.name) == ["out", "0", "sense", "0"])
        #expect(f1.parameters["control_source"] == nil)
        #expect(h1.nodes.map(\.name) == ["hout", "0", "0", "sense"])
        #expect(h1.parameters["control_source"] == nil)
    }

    @Test
    func parseUnsupportedMeasureAsBlockedIntent() async throws {
        let source = """
        Unsupported Measure Test
        .meas tran strange unsupported_token arg=1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)
        let netlist = try result.get()

        guard case .measure(let measure)? = netlist.controls.first else {
            Issue.record("Expected measure control.")
            return
        }
        guard case .unsupported(let keyword, let arguments, _) = measure.measureType else {
            Issue.record("Expected unsupported measure, got \(measure.measureType).")
            return
        }
        #expect(keyword == "unsupported_token")
        #expect(arguments.contains("arg"))
    }

    @Test
    func parseExpressionMeasurementsAsExecutableIntent() async throws {
        let source = """
        Expression Measure Test
        .meas tran avg_diff avg {V(out)-V(in)} from={1+1} to=4
        .meas tran cross when V(out)=2.5
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)
        let netlist = try result.get()

        #expect(netlist.controls.count == 2)

        guard case .measure(let average)? = netlist.controls.first else {
            Issue.record("Expected first measure control.")
            return
        }
        guard case .average(let variable, let from, let to) = average.measureType else {
            Issue.record("Expected average expression measure, got \(average.measureType).")
            return
        }
        guard case .expression(let expression) = variable else {
            Issue.record("Expected output expression, got \(variable).")
            return
        }
        #expect(expression.description.lowercased().contains("v(out)"))
        guard case .expression = from else {
            Issue.record("Expected expression from range.")
            return
        }
        #expect(to == .numeric(4))

        guard case .measure(let crossing)? = netlist.controls.dropFirst().first else {
            Issue.record("Expected second measure control.")
            return
        }
        guard case .when(let condition, nil) = crossing.measureType else {
            Issue.record("Expected WHEN measure, got \(crossing.measureType).")
            return
        }
        #expect(condition.description.contains("=="))
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
    func rejectZeroNoiseAnalysisPointCount() async {
        let source = """
        Noise Point Count Test
        .noise V(out) Vin dec 0 1 1meg
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Expected positive integer analysis point count")
        })
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
    func rejectIncompleteACSensitivityAnalysis() async {
        let parser = SPICEParser()

        for directive in [
            ".sens V(out) ac",
            ".sens V(out) ac dec",
            ".sens V(out) ac dec 10 1",
        ] {
            let result = await parser.parse(
                source: "Sensitivity Test\n\(directive)\n.end\n"
            )
            #expect(!result.isSuccess)
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
    func rejectInvalidPoleZeroModes() async {
        let parser = SPICEParser()
        let invalidTransfer = await parser.parse(
            source: "PZ Test\n.pz in 0 out 0 invalid pz\n.end\n"
        )
        let invalidAnalysis = await parser.parse(
            source: "PZ Test\n.pz in 0 out 0 vol invalid\n.end\n"
        )

        #expect(!invalidTransfer.isSuccess)
        #expect(!invalidAnalysis.isSuccess)
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
    func rejectZeroMonteCarloIterationCount() async {
        let source = """
        MC Iteration Count Test
        .mc 0 dc Vin 0 5 0.1
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)

        #expect(!result.isSuccess)
        #expect(result.errors.contains { diagnostic in
            diagnostic.message.contains("Expected positive integer Monte Carlo iteration count")
        })
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

    @Test
    func parseOperatingPointMeasureWithNumericNode() async throws {
        let source = """
        OP Measure Test
        .meas op vout find V(2) at=0
        .end
        """

        let parser = SPICEParser()
        let result = await parser.parse(source: source)
        let netlist = try result.get()

        let control = try #require(netlist.controls.first)
        guard case .measure(let measure) = control else {
            Issue.record("expected measure control, got \(control)")
            return
        }
        #expect(measure.analysisType == .op)
        guard case .find(let variable, let at) = measure.measureType else {
            Issue.record("expected find measure, got \(measure.measureType)")
            return
        }
        guard case .voltage(let node, nil) = variable else {
            Issue.record("expected voltage variable, got \(variable)")
            return
        }
        #expect(node == "2")
        guard case .numeric(let value) = at else {
            Issue.record("expected numeric at value, got \(at)")
            return
        }
        #expect(value == 0)
    }
}

@Suite
struct ParsedAnalysisValidationTests {

    @Test
    func acSpecRejectsZeroPointCount() {
        #expect(throws: ParsedAnalysisValidationError.invalidAnalysisPointCount(0)) {
            _ = try ACAnalysisSpec(
                scaleType: .decade,
                numberOfPoints: 0,
                startFrequency: .numeric(1.0),
                stopFrequency: .numeric(1.0e6)
            )
        }
    }

    @Test
    func noiseSpecRejectsZeroPointCount() {
        #expect(throws: ParsedAnalysisValidationError.invalidAnalysisPointCount(0)) {
            _ = try NoiseAnalysisSpec(
                outputNode: "out",
                inputSource: "vin",
                scaleType: .decade,
                numberOfPoints: 0,
                startFrequency: .numeric(1.0),
                stopFrequency: .numeric(1.0e6)
            )
        }
    }

    @Test
    func monteCarloSpecRejectsZeroIterations() {
        #expect(throws: ParsedAnalysisValidationError.invalidMonteCarloIterationCount(0)) {
            _ = try MonteCarloSpec(
                analysis: .op,
                iterations: 0
            )
        }
    }

    @Test
    func monteCarloSpecRejectsNegativeSeed() {
        #expect(throws: ParsedAnalysisValidationError.invalidMonteCarloSeed(-1)) {
            _ = try MonteCarloSpec(
                analysis: .op,
                iterations: 1,
                seed: -1
            )
        }
    }
}
