import Testing
import CoreSpiceParserSPICE
import CoreSpiceParser
import CoreSpiceParsedIR

@Suite("SPICE quoted value semantics", .timeLimit(.minutes(1)))
struct SPICEQuotedValueTests {
    enum NumericExpression: String, CaseIterable, Sendable {
        case product = "41.6503*1.024"
        case reference = "ref"
        case function = "sqrt(ref)"
        case unaryPlus = "+2"

        var expected: ParsedExpression {
            switch self {
            case .product:
                return .binaryOperation(.multiply, .literal(41.6503), .literal(1.024))
            case .reference:
                return .identifier("ref")
            case .function:
                return .functionCall(name: "sqrt", arguments: [.identifier("ref")])
            case .unaryPlus:
                return .unaryOperation(.plus, .literal(2))
            }
        }
    }

    @Test(arguments: NumericExpression.allCases)
    func numericQuotesRetainExpressionMeaningAcrossValueRoles(expression: NumericExpression) async throws {
        let source = """
        Quoted numeric values
        .param ref=2 result='\(expression.rawValue)'
        .model dm d is='\(expression.rawValue)'
        .subckt cell p n gain='\(expression.rawValue)'
        Rinside p n 1k
        .ends cell
        X1 out 0 cell gain='\(expression.rawValue)'
        R1 out 0 '\(expression.rawValue)'
        .end
        """
        let result = await SPICEParser().parse(source: source)
        let parsed = try result.get()
        #expect(parsed.parameters["result"] == expression.expected)
        #expect(parsed.models.first?.parameters["is"] == .expression(expression.expected))
        #expect(parsed.subcircuits.first?.parameters["gain"] == .expression(expression.expected))
        let actual = try #require(parsed.components.first { $0.name == "x1" })
        let resistor = try #require(parsed.components.first { $0.name == "r1" })
        #expect(actual.parameters["gain"] == .expression(expression.expected))
        #expect(resistor.parameters["r"] == .expression(expression.expected))

        let serialized = SPICESerializer().serialize(parsed)
        let roundTrip = await SPICEParser().parse(source: serialized)
        let restored = try roundTrip.get()
        #expect(restored.parameters == parsed.parameters)
        #expect(restored.models.first?.parameters == parsed.models.first?.parameters)
        #expect(restored.subcircuits.first?.parameters == parsed.subcircuits.first?.parameters)
        #expect(restored.components.map(\.parameters) == parsed.components.map(\.parameters))
    }

    @Test
    func conditionalQuotesUseParameterAndFunctionEvaluation() async throws {
        let source = """
        Quoted conditional expression
        .param ref='2'
        .func twice(x) {2*x}
        .if 'twice(ref)>3'
        Rpass out 0 1k
        .else
        Rfail out 0 2k
        .endif
        .end
        """
        let result = await SPICEParser().parse(source: source)
        let parsed = try result.get()
        #expect(parsed.parameters["ref"] == .literal(2))
        #expect(parsed.components.map(\.name) == ["rpass"])
        #expect(parsed.components.first?.parameters["r"] == .numeric(1000))
    }

    @Test
    func opaqueDoubleQuotedValuesRoundTripDelimitersAndBackslashes() async throws {
        let quoted = #""Keep \"Q\"\\Folder's""#
        let expected = #"Keep "Q"\Folder's"#
        let source = """
        Opaque quoted values
        .model dm d note=\(quoted)
        .subckt cell p n note=\(quoted)
        Rinside p n 1k
        .ends cell
        X1 out 0 cell note=\(quoted)
        R1 out 0 1k note=\(quoted)
        .end
        """
        let result = await SPICEParser().parse(source: source)
        let parsed = try result.get()
        #expect(parsed.models.first?.parameters["note"] == .string(expected))
        #expect(parsed.subcircuits.first?.parameters["note"] == .string(expected))
        #expect(parsed.components.map(\.name) == ["x1", "r1"])
        #expect(parsed.components.allSatisfy { $0.parameters["note"] == .string(expected) })
        let serialized = SPICESerializer().serialize(parsed)
        let roundTrip = await SPICEParser().parse(source: serialized)
        let restored = try roundTrip.get()
        #expect(restored.models.first?.parameters == parsed.models.first?.parameters)
        #expect(restored.subcircuits.first?.parameters == parsed.subcircuits.first?.parameters)
        #expect(restored.components.map(\.parameters) == parsed.components.map(\.parameters))
    }

    @Test
    func numericParameterRejectsOpaqueDoubleQuotedText() async throws {
        let file = "opaque-numeric.spice"
        let result = await SPICEParser().parse(
            source: "Opaque numeric rejection\n.param bad=\"2\"\n.end\n", fileName: file
        )
        #expect(!result.isSuccess)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
        let diagnostic = try #require(result.errors.first)
        #expect(diagnostic.location == SourceLocation(file: file, line: 2, column: 12))
    }

    enum InvalidNumericValue: CaseIterable, Sendable {
        case empty, trailingToken, malformedOperator, unknownCharacter, unterminated

        var source: String {
            switch self {
            case .empty: return "''"
            case .trailingToken: return "'2 3'"
            case .malformedOperator: return "'2*'"
            case .unknownCharacter: return "'2@'"
            case .unterminated: return "'2"
            }
        }

        var errorColumn: Int {
            switch self {
            case .empty: return 10
            case .trailingToken, .malformedOperator: return 12
            case .unknownCharacter: return 11
            case .unterminated: return 9
            }
        }
    }

    @Test(arguments: ["\n", "\r\n"], InvalidNumericValue.allCases)
    func invalidQuotedContinuationsReportPhysicalLocations(
        lineEnding: String, value: InvalidNumericValue
    ) async throws {
        let file = "quoted-continuation.spice"
        let source = [
            "Quoted continuation diagnostic", ".param seed=1", "* Intervening comment", "",
            "  + bad=\(value.source)", ".end", ""
        ].joined(separator: lineEnding)
        let result = await SPICEParser().parse(source: source, fileName: file)
        #expect(!result.isSuccess)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
        let diagnostic = try #require(result.errors.first)
        #expect(diagnostic.location == SourceLocation(file: file, line: 5, column: value.errorColumn))
    }

    @Test(arguments: ["'", "\""], [".include", ".lib", ".hdl"])
    func unterminatedTextRolesCannotBecomeSuccessfulPaths(delimiter: String, directive: String) async throws {
        let file = "unclosed-path.spice"
        let result = await SPICEParser().parse(
            source: "Unclosed path\n\(directive) \(delimiter)Exact/Path\n.end\n", fileName: file
        )
        #expect(!result.isSuccess)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
        let diagnostic = try #require(result.errors.first)
        #expect(diagnostic.location == SourceLocation(file: file, line: 2, column: directive.count + 2))
    }

    @Test(arguments: [false, true])
    func bothDelimitersPreserveExactIncludeLibraryAndHDLPaths(singleQuoted: Bool) async throws {
        let quoted = singleQuoted
            ? #"'Models/Exact "A"\\B\'s.spice'"#
            : #""Models/Exact \"A\"\\B's.spice""#
        let expected = #"Models/Exact "A"\B's.spice"#
        let source = """
        Exact path values
        .include \(quoted)
        .lib \(quoted) TT
        .hdl \(quoted)
        .end
        """
        let result = await SPICEParser().parse(source: source)
        let parsed = try result.get()
        #expect(textPaths(in: parsed) == [expected, expected, expected])
        let serialized = SPICESerializer().serialize(parsed)
        let roundTrip = await SPICEParser().parse(source: serialized)
        let restored = try roundTrip.get()
        #expect(textPaths(in: restored) == [expected, expected, expected])
        let library = try #require(parsed.controls.first { control in
            if case .library = control { return true }
            return false
        })
        guard case .library(_, let section, _) = library else {
            Issue.record("Expected a library control")
            return
        }
        #expect(section == "tt")
    }

    @Test(arguments: ["'", "\""], ["4.5", "4.50.0-Exact"])
    func modelVersionRemainsExactTextAndQuotedLiteralLevelRemainsStructural(
        delimiter: String, version: String
    ) async throws {
        let source = "Exact model version\n.model nch nmos level='54' version=\(delimiter)\(version)\(delimiter)\n.end\n"
        let result = await SPICEParser().parse(source: source)
        let parsed = try result.get()
        let model = try #require(parsed.models.first)
        #expect(model.level == 54)
        #expect(model.parameters["version"] == .string(version))
        let roundTrip = await SPICEParser().parse(source: SPICESerializer().serialize(parsed))
        let restored = try roundTrip.get()
        #expect(restored.models.first?.level == 54)
        #expect(restored.models.first?.parameters["version"] == .string(version))
    }

    @Test(arguments: ["'ref'", "'54.5'", "'1e30'", "\"54\""])
    func suppliedStructuralLevelCannotSilentlyBecomeDefault(value: String) async throws {
        let file = "quoted-level.spice"
        let result = await SPICEParser().parse(
            source: "Invalid structural level\n.param ref=54\n.model nch nmos level=\(value)\n.end\n",
            fileName: file
        )
        #expect(!result.isSuccess)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
        let diagnostic = try #require(result.errors.first)
        #expect(diagnostic.location == SourceLocation(file: file, line: 3, column: 23))
        #expect(diagnostic.message == (value == "'ref'" || value == "\"54\""
            ? "Model level must be a constant integer literal"
            : "Model level must be a representable integer"))
    }

    @Test(arguments: ["A designer's circuit", "A title with an unmatched \" mark"])
    func rawTitleQuotesDoNotBecomeValueDiagnostics(title: String) async throws {
        let result = await SPICEParser().parse(
            source: "\(title)\nR1 1 0 1\n.end\n", fileName: "raw-title-quotes.spice"
        )
        let parsed = try result.get()
        #expect(parsed.components.count == 1)
        let resistor = try #require(parsed.components.first)
        #expect(resistor.name == "r1")
        #expect(resistor.nodes.map(\.name) == ["1", "0"])
        #expect(resistor.parameters == ["r": .numeric(1)])
    }

    @Test(arguments: ["R1 out 0 \"2\"", "R1 out 0 1 '2'"])
    func numericSlotsRejectOpaqueAndUnassignedQuotedValues(component: String) async throws {
        let result = await SPICEParser().parse(
            source: "Invalid quoted numeric slot\n\(component)\n.end\n", fileName: "quoted-slot.spice"
        )
        #expect(!result.isSuccess)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
        let diagnostic = try #require(result.errors.first)
        #expect(diagnostic.location?.file == "quoted-slot.spice")
        #expect(diagnostic.location?.line == 2)
    }

    private func textPaths(in netlist: ParsedNetlist) -> [String] {
        netlist.controls.compactMap { control in
            switch control {
            case .include(let path, _), .library(let path, _, _), .hdl(let path, _):
                return path
            default:
                return nil
            }
        }
    }
}
