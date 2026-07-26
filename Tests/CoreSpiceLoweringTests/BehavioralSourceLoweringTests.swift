import Testing
@testable import CoreSpiceIR
@testable import CoreSpiceLowering
@testable import CoreSpiceParsedIR

@Suite("Behavioral-source lowering")
struct BehavioralSourceLoweringTests {
    @Test("Current output owns no branch and preserves referenced nodes")
    func lowersCurrentOutput() throws {
        let component = ParsedComponent(
            name: "B1",
            type: .behavioral,
            nodes: ["out", "0"],
            parameters: [
                "i": .expression(
                    .binaryOperation(
                        .divide,
                        .functionCall(name: "V", arguments: [.identifier("control")]),
                        .literal(1_000)
                    )
                )
            ]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [component])
        )
        let instance = try #require(circuit.instances.first)

        #expect(instance.typeName == "behavioral_isource")
        #expect(instance.ownedBranches.isEmpty)
        #expect(instance.referencedNodes.count == 1)
    }

    @Test("Forward source-current reference resolves through canonical branch ownership")
    func resolvesForwardBranchReference() throws {
        let behavioral = ParsedComponent(
            name: "B1",
            type: .behavioral,
            nodes: ["out", "0"],
            parameters: [
                "v": .expression(
                    .functionCall(name: "I", arguments: [.identifier("V1")])
                )
            ]
        )
        let voltageSource = ParsedComponent(
            name: "V1",
            type: .voltageSource,
            nodes: ["in", "0"],
            parameters: ["v": .numeric(1)]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [behavioral, voltageSource])
        )
        let instance = try #require(circuit.instances.first { $0.name == "B1" })
        let referencedSource = try #require(
            circuit.instances.first { $0.name == "V1" }
        )

        #expect(instance.referencedBranches.count == 1)
        #expect(instance.referencedBranches[0] == referencedSource.ownedBranches[0])
    }

    @Test("User functions are inlined while preserving runtime variables")
    func lowersUserFunctions() throws {
        let function = ParsedControlStatement.function(
            name: "scaled",
            parameters: ["x", "gain"],
            body: .binaryOperation(
                .multiply,
                .identifier("x"),
                .identifier("gain")
            ),
            location: nil
        )
        let component = ParsedComponent(
            name: "B1",
            type: .behavioral,
            nodes: ["out", "0"],
            parameters: [
                "v": .expression(
                    .functionCall(
                        name: "scaled",
                        arguments: [
                            .functionCall(
                                name: "V",
                                arguments: [.identifier("control")]
                            ),
                            .literal(3),
                        ]
                    )
                )
            ]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [component], controls: [function])
        )
        let instance = try #require(circuit.instances.first)

        #expect(instance.referencedNodes.count == 1)
        guard case .behavioralExpression(
            .binary(.multiply, .variable(.nodeVoltage), .constant(3))
        ) = instance.parameters["v"] else {
            Issue.record("Expected the user function to be inlined")
            return
        }
    }

    @Test("Malformed output contracts and recursive runtime functions fail explicitly")
    func rejectsMalformedBehavioralSources() {
        let missingOutput = ParsedComponent(
            name: "Bmissing",
            type: .behavioral,
            nodes: ["out", "0"]
        )
        let recursiveFunction = ParsedControlStatement.function(
            name: "loop",
            parameters: ["x"],
            body: .functionCall(name: "loop", arguments: [.identifier("x")]),
            location: nil
        )
        let recursiveSource = ParsedComponent(
            name: "Brecursive",
            type: .behavioral,
            nodes: ["out", "0"],
            parameters: [
                "v": .expression(
                    .functionCall(name: "loop", arguments: [.literal(1)])
                )
            ]
        )

        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering().lower(
                ParsedNetlist(components: [missingOutput])
            )
        }
        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering().lower(
                ParsedNetlist(
                    components: [recursiveSource],
                    controls: [recursiveFunction]
                )
            )
        }
    }
}
