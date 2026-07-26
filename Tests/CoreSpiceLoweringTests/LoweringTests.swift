import Foundation
import Testing
@testable import CoreSpiceLowering
@testable import CoreSpiceParsedIR
@testable import CoreSpiceIR

@Suite
struct ExpressionEvaluatorTests {

    @Test
    func evaluateLiteral() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context)

        let result = try evaluator.evaluate(.literal(42.0))
        #expect(result == 42.0)
    }

    @Test
    func evaluateParameter() throws {
        let context = LoweringContext()
        context.setParameter("vdd", value: 1.8)
        let evaluator = ExpressionEvaluator(context: context)

        let result = try evaluator.evaluate(.identifier("vdd"))
        #expect(result == 1.8)
    }

    @Test
    func evaluateUndefinedParameter() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context)

        #expect(throws: LoweringError.self) {
            _ = try evaluator.evaluate(.identifier("undefined"))
        }
    }

    @Test
    func evaluateUnaryNegate() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context)

        let expr = ParsedExpression.unaryOperation(.negate, .literal(5.0))
        let result = try evaluator.evaluate(expr)
        #expect(result == -5.0)
    }

    @Test
    func evaluateBinaryOperations() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context)

        // Addition
        let add = ParsedExpression.binaryOperation(.add, .literal(2), .literal(3))
        #expect(try evaluator.evaluate(add) == 5.0)

        // Multiplication
        let mul = ParsedExpression.binaryOperation(.multiply, .literal(4), .literal(5))
        #expect(try evaluator.evaluate(mul) == 20.0)

        // Division
        let div = ParsedExpression.binaryOperation(.divide, .literal(10), .literal(2))
        #expect(try evaluator.evaluate(div) == 5.0)

        // Power
        let pow = ParsedExpression.binaryOperation(.power, .literal(2), .literal(3))
        #expect(try evaluator.evaluate(pow) == 8.0)
    }

    @Test
    func evaluateFunctions() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context)

        // sqrt
        let sqrt = ParsedExpression.functionCall(name: "sqrt", arguments: [.literal(4.0)])
        #expect(try evaluator.evaluate(sqrt) == 2.0)

        // abs
        let abs = ParsedExpression.functionCall(name: "abs", arguments: [.literal(-5.0)])
        #expect(try evaluator.evaluate(abs) == 5.0)

        // min
        let min = ParsedExpression.functionCall(name: "min", arguments: [.literal(3), .literal(1), .literal(2)])
        #expect(try evaluator.evaluate(min) == 1.0)

        // max
        let max = ParsedExpression.functionCall(name: "max", arguments: [.literal(3), .literal(1), .literal(2)])
        #expect(try evaluator.evaluate(max) == 3.0)
    }

    @Test
    func randomFunctionsRejectIgnoredArguments() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context, randomUniform: { 0.5 })

        let randWithArgument = ParsedExpression.functionCall(name: "rand", arguments: [.literal(1)])
        #expect(
            loweringFailureReason(for: randWithArgument, evaluator: evaluator)
                == "Expected 0 arguments, got 1"
        )

        let gaussWithExtraArguments = ParsedExpression.functionCall(
            name: "gauss",
            arguments: [.literal(1), .literal(0.1), .literal(3), .literal(4)]
        )
        #expect(
            loweringFailureReason(for: gaussWithExtraArguments, evaluator: evaluator)
                == "Expected 2 or 3 arguments, got 4"
        )
    }

    @Test
    func gaussianFunctionsEvaluateThreeArgumentVariation() throws {
        let context = LoweringContext()
        let uniform = exp(-0.5)
        let unitGaussian = sqrt(-2 * log(uniform)) * cos(2 * Double.pi * uniform)
        let evaluator = ExpressionEvaluator(context: context, randomUniform: { uniform })

        let relative = ParsedExpression.functionCall(
            name: "gauss",
            arguments: [.literal(100), .literal(0.06), .literal(3)]
        )
        let absolute = ParsedExpression.functionCall(
            name: "agauss",
            arguments: [.literal(1e-9), .literal(1e-10), .literal(2)]
        )
        let evaluatedRelative = try evaluator.evaluate(relative)
        let evaluatedAbsolute = try evaluator.evaluate(absolute)
        let expectedRelative = 100 + 100 * 0.06 / 3 * unitGaussian
        let expectedAbsolute = 1e-9 + 1e-10 / 2 * unitGaussian

        #expect(abs(evaluatedRelative - expectedRelative) < 1e-12)
        #expect(abs(evaluatedAbsolute - expectedAbsolute) < 1e-21)
    }

    @Test
    func gaussianFunctionsRejectInvalidRandomSource() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context, randomUniform: { -0.1 })
        let expression = ParsedExpression.functionCall(name: "agauss", arguments: [.literal(1), .literal(0.1)])

        #expect(
            loweringFailureReason(for: expression, evaluator: evaluator)
                == "Random source returned a value outside [0, 1)"
        )
    }

    @Test
    func evaluateUserDefinedFunction() throws {
        let context = LoweringContext()
        context.registerFunction(
            name: "scale",
            parameters: ["x", "factor"],
            body: .binaryOperation(.multiply, .identifier("x"), .identifier("factor"))
        )
        let evaluator = ExpressionEvaluator(context: context)

        let call = ParsedExpression.functionCall(name: "scale", arguments: [.literal(4), .literal(2.5)])
        #expect(try evaluator.evaluate(call) == 10.0)
    }

    @Test
    func recursiveUserDefinedFunctionFailsLoud() throws {
        let context = LoweringContext()
        context.registerFunction(
            name: "loop",
            parameters: ["x"],
            body: .functionCall(name: "loop", arguments: [.identifier("x")])
        )
        let evaluator = ExpressionEvaluator(context: context)

        #expect(throws: LoweringError.self) {
            _ = try evaluator.evaluate(.functionCall(name: "loop", arguments: [.literal(1)]))
        }
    }

    @Test
    func evaluateConditional() throws {
        let context = LoweringContext()
        let evaluator = ExpressionEvaluator(context: context)

        let trueCond = ParsedExpression.conditional(
            condition: .literal(1),
            then: .literal(10),
            else: .literal(20)
        )
        #expect(try evaluator.evaluate(trueCond) == 10.0)

        let falseCond = ParsedExpression.conditional(
            condition: .literal(0),
            then: .literal(10),
            else: .literal(20)
        )
        #expect(try evaluator.evaluate(falseCond) == 20.0)
    }

    private func loweringFailureReason(
        for expression: ParsedExpression,
        evaluator: ExpressionEvaluator
    ) -> String {
        do {
            _ = try evaluator.evaluate(expression)
            Issue.record("Expected expression evaluation to fail.")
            return ""
        } catch let error as LoweringError {
            guard case .expressionEvaluationFailed(_, let reason) = error else {
                Issue.record("Unexpected lowering error: \(error)")
                return ""
            }
            return reason
        } catch {
            Issue.record("Unexpected error: \(error)")
            return ""
        }
    }
}

@Suite
struct LoweringContextTests {

    @Test
    func parameterScoping() throws {
        let context = LoweringContext()
        context.setParameter("global", value: 1.0)

        try context.enterScope(parameters: ["local": 2.0])

        #expect(context.parameter("global") == 1.0)
        #expect(context.parameter("local") == 2.0)

        context.exitScope()

        #expect(context.parameter("global") == 1.0)
        #expect(context.parameter("local") == nil)
    }

    @Test
    func maxDepthEnforcement() throws {
        let context = LoweringContext(maxDepth: 3)

        try context.enterScope()
        try context.enterScope()
        try context.enterScope()

        #expect(throws: LoweringError.self) {
            try context.enterScope()
        }
    }

    @Test
    func modelRegistration() {
        let context = LoweringContext()

        let model = ParsedModel(name: "nch", type: .nmos, level: 1)
        context.registerModel(model)

        #expect(context.model("nch") != nil)
        #expect(context.model("NCH") != nil) // Case insensitive
        #expect(context.model("undefined") == nil)
    }

    @Test
    func subcircuitRegistration() {
        let context = LoweringContext()

        let subckt = ParsedSubcircuit(
            name: "inv",
            ports: ["in", "out"],
            body: .empty
        )
        context.registerSubcircuit(subckt)

        #expect(context.subcircuit("inv") != nil)
        #expect(context.subcircuit("INV") != nil)
        #expect(context.subcircuit("undefined") == nil)
    }
}

@Suite
struct NetlistLoweringTests {

    @Test
    func lowerSimpleResistor() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .numeric(1000)]
                )
            ]
        )

        let lowering = NetlistLowering()
        let circuit = try lowering.lower(netlist)

        #expect(circuit.instances.count == 1)
        #expect(circuit.instances[0].name == "R1")
        #expect(circuit.instances[0].typeName == "resistor")
    }

    @Test
    func lowerWithParameters() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .expression(.identifier("rval"))]
                )
            ],
            parameters: ["rval": .literal(2000)]
        )

        let lowering = NetlistLowering()
        let circuit = try lowering.lower(netlist)

        #expect(circuit.instances.count == 1)
        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 2000.0)
        }
    }

    @Test
    func lowerResolvesOutOfOrderParameterDependencies() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .expression(.identifier("rload"))]
                )
            ],
            parameters: [
                "rload": .binaryOperation(.multiply, .identifier("runit"), .literal(4)),
                "runit": .literal(500)
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)

        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 2000.0)
        } else {
            Issue.record("Expected lowered resistor parameter.")
        }
    }

    @Test
    func lowerVoltageControlledSwitchWithModelParameters() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "S1",
                    type: .switch_,
                    nodes: ["in", "out", "ctrl", "0"],
                    modelName: "swmod"
                )
            ],
            models: [
                ParsedModel(
                    name: "swmod",
                    type: .sw,
                    parameters: [
                        "ron": .numeric(10),
                        "roff": .numeric(1.0e9),
                        "vt": .numeric(2),
                        "vh": .numeric(0),
                    ]
                )
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)

        let instance = try #require(circuit.instances.first)
        #expect(instance.typeName == "vswitch")
        if case .real(let onResistance) = instance.parameters["ron"] {
            #expect(onResistance == 10)
        } else {
            Issue.record("Expected lowered switch on resistance.")
        }
        if case .real(let threshold) = instance.parameters["vt"] {
            #expect(threshold == 2)
        } else {
            Issue.record("Expected lowered switch threshold.")
        }
    }

    @Test
    func lowerCurrentControlledSwitchWithModelParameters() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "W1",
                    type: .currentSwitch,
                    nodes: ["in", "out", "sense", "0"],
                    modelName: "cswmod"
                )
            ],
            models: [
                ParsedModel(
                    name: "cswmod",
                    type: .csw,
                    parameters: [
                        "ron": .numeric(10),
                        "roff": .numeric(1.0e9),
                        "it": .numeric(1.0e-3),
                        "ih": .numeric(0),
                    ]
                )
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)

        let instance = try #require(circuit.instances.first)
        #expect(instance.typeName == "cswitch")
        #expect(circuit.branches.count == 1)
        if case .real(let onResistance) = instance.parameters["ron"] {
            #expect(onResistance == 10)
        } else {
            Issue.record("Expected lowered current switch on resistance.")
        }
        if case .real(let thresholdCurrent) = instance.parameters["it"] {
            #expect(thresholdCurrent == 1.0e-3)
        } else {
            Issue.record("Expected lowered current switch threshold.")
        }
    }

    @Test
    func lowerJFETWithModelParameters() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "J1",
                    type: .jfet,
                    nodes: ["drain", "gate", "source"],
                    modelName: "jmod"
                )
            ],
            models: [
                ParsedModel(
                    name: "jmod",
                    type: .njf,
                    parameters: [
                        "beta": .numeric(1.0e-3),
                        "vto": .numeric(-2.0),
                        "lambda": .numeric(0.02),
                        "cgs": .numeric(1.0e-12),
                        "cgd": .numeric(2.0e-12),
                        "area": .numeric(2.0),
                    ]
                )
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)
        let instance = try #require(circuit.instances.first)
        #expect(instance.typeName == "njfet")
        if case .real(let beta) = instance.parameters["beta"] {
            #expect(beta == 1.0e-3)
        } else {
            Issue.record("Expected lowered JFET beta.")
        }
        if case .real(let cgd) = instance.parameters["cgd"] {
            #expect(cgd == 2.0e-12)
        } else {
            Issue.record("Expected lowered JFET gate-drain capacitance.")
        }
        if case .real(let area) = instance.parameters["area"] {
            #expect(area == 2.0)
        } else {
            Issue.record("Expected lowered JFET area multiplier.")
        }
    }

    @Test
    func lowerJFETSeriesResistancesIntoExplicitResistors() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "J1",
                    type: .jfet,
                    nodes: ["drain", "gate", "source"],
                    modelName: "jmod"
                )
            ],
            models: [
                ParsedModel(
                    name: "jmod",
                    type: .njf,
                    parameters: [
                        "beta": .numeric(1.0e-3),
                        "vto": .numeric(-2.0),
                        "rd": .numeric(100),
                        "rs": .numeric(200),
                    ]
                )
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)
        let instances = Dictionary(uniqueKeysWithValues: circuit.instances.map { ($0.name, $0) })

        #expect(instances["J1"]?.typeName == "njfet")
        #expect(instances["J1.rd"]?.typeName == "resistor")
        #expect(instances["J1.rs"]?.typeName == "resistor")
        #expect(instances["J1"]?.parameters["rd"] == nil)
        #expect(instances["J1"]?.parameters["rs"] == nil)
        if case .real(let rd) = instances["J1.rd"]?.parameters["r"] {
            #expect(rd == 100)
        } else {
            Issue.record("Expected lowered JFET drain resistance.")
        }
        if case .real(let rs) = instances["J1.rs"]?.parameters["r"] {
            #expect(rs == 200)
        } else {
            Issue.record("Expected lowered JFET source resistance.")
        }
    }

    @Test
    func lowerSourceReferencedCurrentControlledElements() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "VCTRL",
                    type: .voltageSource,
                    nodes: ["ctrl", "0"],
                    parameters: ["v": .numeric(1)]
                ),
                ParsedComponent(
                    name: "F1",
                    type: .cccs,
                    nodes: ["out", "0"],
                    parameters: [
                        "control_source": .string("VCTRL"),
                        "f": .numeric(2),
                    ]
                ),
                ParsedComponent(
                    name: "H1",
                    type: .ccvs,
                    nodes: ["hout", "0"],
                    parameters: [
                        "control_source": .string("VCTRL"),
                        "h": .numeric(1000),
                    ]
                ),
                ParsedComponent(
                    name: "W1",
                    type: .currentSwitch,
                    nodes: ["vdd", "swout"],
                    modelName: "cswmod",
                    parameters: [
                        "control_source": .string("VCTRL")
                    ]
                ),
            ],
            models: [
                ParsedModel(
                    name: "cswmod",
                    type: .csw,
                    parameters: [
                        "ron": .numeric(10),
                        "roff": .numeric(1.0e9),
                        "it": .numeric(1.0e-3),
                        "ih": .numeric(0),
                    ]
                )
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)
        let instancesByName = Dictionary(uniqueKeysWithValues: circuit.instances.map { ($0.name, $0) })

        #expect(instancesByName["F1"]?.typeName == "cccs_ref")
        #expect(instancesByName["H1"]?.typeName == "ccvs_ref")
        #expect(instancesByName["W1"]?.typeName == "cswitch_ref")
        #expect(circuit.branches.count == 2)

        if case .string(let controlSource) = instancesByName["F1"]?.parameters["control_source"] {
            #expect(controlSource == "VCTRL")
        } else {
            Issue.record("Expected F1 control source reference.")
        }

        if case .string(let controlSource) = instancesByName["W1"]?.parameters["control_source"] {
            #expect(controlSource == "VCTRL")
        } else {
            Issue.record("Expected W1 control source reference.")
        }
    }

    @Test
    func lowerCoupledInductorsAsBranchReferencesAfterInductors() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "K1",
                    type: .coupledInductors,
                    nodes: ["L1", "L2"],
                    parameters: ["k": .numeric(0.5)]
                ),
                ParsedComponent(
                    name: "L1",
                    type: .inductor,
                    nodes: ["in", "0"],
                    parameters: ["l": .numeric(4.0e-6)]
                ),
                ParsedComponent(
                    name: "L2",
                    type: .inductor,
                    nodes: ["out", "0"],
                    parameters: ["l": .numeric(9.0e-6)]
                ),
            ]
        )

        let circuit = try NetlistLowering().lower(netlist)
        let instancesByName = Dictionary(uniqueKeysWithValues: circuit.instances.map { ($0.name, $0) })

        #expect(circuit.instances.map(\.name) == ["L1", "L2", "K1"])
        #expect(circuit.branches.count == 2)
        #expect(Set(circuit.branchNames.values) == ["L1", "L2"])
        #expect(!circuit.nodeNames.values.contains("L1"))
        #expect(!circuit.nodeNames.values.contains("L2"))

        let coupling = try #require(instancesByName["K1"])
        #expect(coupling.typeName == "mutual")
        #expect(coupling.nodes.isEmpty)
        if case .real(let coefficient) = coupling.parameters["k"] {
            #expect(coefficient == 0.5)
        } else {
            Issue.record("Expected lowered mutual coupling coefficient.")
        }
        if case .string(let inductorA) = coupling.parameters["inductor_a"] {
            #expect(inductorA == "L1")
        } else {
            Issue.record("Expected first inductor branch reference.")
        }
        if case .string(let inductorB) = coupling.parameters["inductor_b"] {
            #expect(inductorB == "L2")
        } else {
            Issue.record("Expected second inductor branch reference.")
        }
    }

    @Test
    func lowerWithUserDefinedFunctionParameter() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .expression(.functionCall(name: "scale", arguments: [.identifier("base")]))]
                )
            ],
            controls: [
                .function(
                    name: "scale",
                    parameters: ["x"],
                    body: .binaryOperation(.multiply, .identifier("x"), .literal(2)),
                    location: nil
                )
            ],
            parameters: ["base": .literal(1000)]
        )

        let lowering = NetlistLowering()
        let circuit = try lowering.lower(netlist)

        #expect(circuit.instances.count == 1)
        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 2000.0)
        } else {
            Issue.record("Expected lowered resistor parameter.")
        }
    }
}

@Suite
struct SubcircuitExpansionTests {

    @Test
    func expandSimpleSubcircuit() throws {
        // Define a subcircuit with a single resistor
        let resistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["p", "n"],
            parameters: ["r": .expression(.identifier("rval"))]
        )

        let subcircuit = ParsedSubcircuit(
            name: "load",
            ports: ["p", "n"],
            parameters: ["rval": .numeric(1000)],
            body: ParsedNetlistBody(components: [resistor])
        )

        // Instantiate the subcircuit
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["in", "out"],
            modelName: "load",
            parameters: ["rval": .numeric(2000)]
        )

        let netlist = ParsedNetlist(
            components: [instance],
            subcircuits: [subcircuit]
        )

        let lowering = NetlistLowering()
        let circuit = try lowering.lower(netlist)

        // Should have expanded to a single resistor with prefixed name
        #expect(circuit.instances.count == 1)
        #expect(circuit.instances[0].name.contains("X1"))
    }

    @Test
    func nestedSubcircuitExpansion() throws {
        // Inner subcircuit
        let innerResistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["a", "b"],
            parameters: ["r": .numeric(500)]
        )
        let innerSubcircuit = ParsedSubcircuit(
            name: "inner",
            ports: ["a", "b"],
            body: ParsedNetlistBody(components: [innerResistor])
        )

        // Outer subcircuit that uses inner
        let innerInstance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["p", "n"],
            modelName: "inner"
        )
        let outerSubcircuit = ParsedSubcircuit(
            name: "outer",
            ports: ["p", "n"],
            body: ParsedNetlistBody(components: [innerInstance])
        )

        // Top-level instantiation
        let topInstance = ParsedComponent(
            name: "Xtop",
            type: .subcircuitInstance,
            nodes: ["in", "0"],
            modelName: "outer"
        )

        let netlist = ParsedNetlist(
            components: [topInstance],
            subcircuits: [innerSubcircuit, outerSubcircuit]
        )

        let lowering = NetlistLowering()
        let circuit = try lowering.lower(netlist)

        // Should be fully flattened to just the resistor
        #expect(circuit.instances.count == 1)
        #expect(circuit.instances[0].typeName == "resistor")
    }

    @Test
    func subcircuitParameterOverride() throws {
        let resistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["p", "n"],
            parameters: ["r": .expression(.identifier("rval"))]
        )

        let subcircuit = ParsedSubcircuit(
            name: "res",
            ports: ["p", "n"],
            parameters: ["rval": .numeric(1000)],  // Default value
            body: ParsedNetlistBody(components: [resistor])
        )

        // Override rval to 5000
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["a", "0"],
            modelName: "res",
            parameters: ["rval": .numeric(5000)]
        )

        let netlist = ParsedNetlist(
            components: [instance],
            subcircuits: [subcircuit]
        )

        let lowering = NetlistLowering()
        let circuit = try lowering.lower(netlist)

        #expect(circuit.instances.count == 1)
        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 5000.0)
        }
    }

    @Test
    func undefinedSubcircuitFailureProvidesAgentDiagnostic() throws {
        let location = SourceLocation(file: "agent.cir", line: 4, column: 1)
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["a", "0"],
            modelName: "missing_cell",
            location: location
        )
        let netlist = ParsedNetlist(components: [instance])

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected missing subcircuit lowering to fail.")
        } catch let error as LoweringError {
            let diagnostic = error.diagnostic
            #expect(diagnostic.code == "lowering.undefined_subcircuit")
            #expect(diagnostic.location == location)
            #expect(diagnostic.details["subcircuit"] == "missing_cell")
            #expect(diagnostic.suggestedActions.contains("define-subcircuit"))
            _ = try JSONEncoder().encode(diagnostic)
        }
    }

    @Test
    func subcircuitPortMismatchDiagnosticPreservesExpectedAndActualCounts() throws {
        let subcircuit = ParsedSubcircuit(
            name: "load",
            ports: ["p", "n", "bulk"],
            body: ParsedNetlistBody(components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["p", "n"],
                    parameters: ["r": .numeric(1000)]
                )
            ])
        )
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["a", "0"],
            modelName: "load"
        )
        let netlist = ParsedNetlist(components: [instance], subcircuits: [subcircuit])

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected port-count mismatch to fail.")
        } catch let error as LoweringError {
            let diagnostic = error.diagnostic
            #expect(diagnostic.code == "lowering.subcircuit_port_count_mismatch")
            #expect(diagnostic.subject == "load")
            #expect(diagnostic.details["expected"] == "3")
            #expect(diagnostic.details["got"] == "2")
            #expect(diagnostic.suggestedActions.contains("inspect-subcircuit-port-list"))
        }
    }

    @Test
    func invalidComponentDiagnosticSuggestsModelRepair() throws {
        let mosfet = ParsedComponent(
            name: "M1",
            type: .mosfet,
            nodes: ["d", "g", "s", "b"],
            parameters: [
                "w": .numeric(1e-6),
                "l": .numeric(1e-6)
            ]
        )
        let netlist = ParsedNetlist(components: [mosfet])

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected missing model reference to fail.")
        } catch let error as LoweringError {
            let diagnostic = error.diagnostic
            #expect(diagnostic.code == "lowering.invalid_component")
            #expect(diagnostic.subject == "M1")
            #expect(diagnostic.details["component"] == "M1")
            #expect(diagnostic.details["reason"]?.contains(".model reference") == true)
            #expect(diagnostic.suggestedActions.contains("add-model-reference"))
        }
    }

    @Test
    func subcircuitDefaultParametersCanDependOnOverriddenPublicParameters() throws {
        let resistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["p", "n"],
            parameters: ["r": .expression(.identifier("bottom"))]
        )
        let subcircuit = ParsedSubcircuit(
            name: "load",
            ports: ["p", "n"],
            parameters: [
                "top": .numeric(1000),
                "bottom": .expression(.binaryOperation(.multiply, .identifier("top"), .literal(2)))
            ],
            body: ParsedNetlistBody(components: [resistor])
        )
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["a", "0"],
            modelName: "load",
            parameters: ["top": .numeric(1500)]
        )
        let netlist = ParsedNetlist(components: [instance], subcircuits: [subcircuit])

        let circuit = try NetlistLowering().lower(netlist)

        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 3000.0)
        } else {
            Issue.record("Expected lowered resistor parameter.")
        }
    }

    @Test
    func subcircuitBodyParametersAreScopedAndLowered() throws {
        let resistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["p", "n"],
            parameters: ["r": .expression(.identifier("local_r"))]
        )
        let body = ParsedNetlistBody(
            components: [resistor],
            parameters: [
                "local_r": .binaryOperation(.multiply, .identifier("base_r"), .literal(2))
            ],
            parameterDefinitions: [
                ParsedParameterDefinition(
                    name: "local_r",
                    value: .binaryOperation(.multiply, .identifier("base_r"), .literal(2))
                )
            ]
        )
        let subcircuit = ParsedSubcircuit(
            name: "derived_res",
            ports: ["p", "n"],
            parameters: ["base_r": .numeric(1000)],
            body: body
        )
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["a", "0"],
            modelName: "derived_res",
            parameters: ["base_r": .numeric(1500)]
        )
        let netlist = ParsedNetlist(
            components: [instance],
            subcircuits: [subcircuit]
        )

        let circuit = try NetlistLowering().lower(netlist)

        #expect(circuit.instances.count == 1)
        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 3000.0)
        } else {
            Issue.record("Expected lowered resistor parameter.")
        }
    }

    @Test
    func subcircuitBodyParameterCannotShadowPublicParameter() throws {
        let resistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["p", "n"],
            parameters: ["r": .expression(.identifier("base_r"))]
        )
        let subcircuit = ParsedSubcircuit(
            name: "ambiguous_res",
            ports: ["p", "n"],
            parameters: ["base_r": .numeric(1000)],
            body: ParsedNetlistBody(
                components: [resistor],
                parameters: ["base_r": .literal(2000)]
            )
        )
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["a", "0"],
            modelName: "ambiguous_res",
            parameters: ["base_r": .numeric(1500)]
        )
        let netlist = ParsedNetlist(
            components: [instance],
            subcircuits: [subcircuit]
        )

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected public/local parameter conflict to fail.")
        } catch let error as LoweringError {
            guard case .invalidComponent(let name, let reason) = error else {
                Issue.record("Unexpected lowering error: \(error)")
                return
            }
            #expect(name == "ambiguous_res")
            #expect(reason.contains("conflicts with a public subcircuit parameter"))
        }
    }

    @Test
    func behavioralSourceLowersToCanonicalRuntimeExpression() throws {
        let behavioral = ParsedComponent(
            name: "Bgain",
            type: .behavioral,
            nodes: ["out", "0"],
            parameters: [
                "v": .expression(.functionCall(name: "V", arguments: [.identifier("in")]))
            ]
        )
        let netlist = ParsedNetlist(components: [behavioral])

        let circuit = try NetlistLowering().lower(netlist)
        let instance = try #require(circuit.instances.first)

        #expect(instance.typeName == "behavioral_vsource")
        #expect(instance.ownedBranches.count == 1)
        #expect(instance.referencedNodes.count == 1)
        guard case .behavioralExpression = instance.parameters["v"] else {
            Issue.record("Expected a canonical behavioral expression")
            return
        }
    }

    @Test
    func unsupportedCompactModelFailsBeforeAnalysisBinding() throws {
        let mosfet = ParsedComponent(
            name: "M1",
            type: .mosfet,
            nodes: ["d", "g", "s", "b"],
            modelName: "bsim",
            parameters: [
                "w": .numeric(1e-6),
                "l": .numeric(1e-6)
            ]
        )
        let netlist = ParsedNetlist(
            components: [mosfet],
            models: [ParsedModel(name: "bsim", type: .nmos, level: 49)]
        )

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected BSIM model lowering to fail.")
        } catch let error as LoweringError {
            guard case .invalidComponent(let name, let reason) = error else {
                Issue.record("Unexpected lowering error: \(error)")
                return
            }
            #expect(name == "M1")
            #expect(reason.contains("level 49"))
        }
    }

    @Test
    func missingReferencedModelFailsBeforeAnalysisBinding() throws {
        let diode = ParsedComponent(
            name: "D1",
            type: .diode,
            nodes: ["a", "0"],
            modelName: "missing"
        )
        let netlist = ParsedNetlist(components: [diode])

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected missing model lowering to fail.")
        } catch let error as LoweringError {
            guard case .undefinedModel(let name, _) = error else {
                Issue.record("Unexpected lowering error: \(error)")
                return
            }
            #expect(name == "missing")
        }
    }

    @Test
    func modelDependentComponentWithoutModelFailsBeforeAnalysisBinding() throws {
        let mosfet = ParsedComponent(
            name: "M1",
            type: .mosfet,
            nodes: ["d", "g", "s", "b"],
            parameters: [
                "w": .numeric(1e-6),
                "l": .numeric(1e-6)
            ]
        )
        let netlist = ParsedNetlist(components: [mosfet])

        do {
            _ = try NetlistLowering().lower(netlist)
            Issue.record("Expected missing model reference to fail.")
        } catch let error as LoweringError {
            guard case .invalidComponent(let name, let reason) = error else {
                Issue.record("Unexpected lowering error: \(error)")
                return
            }
            #expect(name == "M1")
            #expect(reason.contains(".model reference"))
        }
    }

    @Test
    func subcircuitBodyModelsAreScopedAndLowered() throws {
        let mosfet = ParsedComponent(
            name: "M1",
            type: .mosfet,
            nodes: ["d", "g", "s", "b"],
            modelName: "pch_local",
            parameters: [
                "w": .numeric(1e-6),
                "l": .numeric(1e-6)
            ]
        )
        let subcircuit = ParsedSubcircuit(
            name: "pmos_cell",
            ports: ["d", "g", "s", "b"],
            body: ParsedNetlistBody(
                components: [mosfet],
                models: [
                    ParsedModel(name: "pch_local", type: .pmos, level: 1)
                ]
            )
        )
        let instance = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["out", "in", "vdd", "vdd"],
            modelName: "pmos_cell"
        )
        let netlist = ParsedNetlist(
            components: [instance],
            subcircuits: [subcircuit]
        )

        let circuit = try NetlistLowering().lower(netlist)

        #expect(circuit.instances.count == 1)
        #expect(circuit.instances[0].typeName == "pmos_l1")
    }
}

@Suite
struct LoweringConfigurationTests {

    @Test
    func defaultConfiguration() {
        let config = NetlistLowering.Configuration.default
        #expect(config.maxExpansionDepth == 64)
        #expect(config.flattenSubcircuits == true)
        #expect(config.expandModels == true)
        #expect(config.evaluateExpressions == true)
        #expect(config.temperature == 27.0)
        #expect(config.parameterOverrides.isEmpty)
    }

    @Test
    func preserveHierarchyConfiguration() {
        let config = NetlistLowering.Configuration.preserveHierarchy
        #expect(config.flattenSubcircuits == false)
        #expect(config.expandModels == false)
        #expect(config.evaluateExpressions == true)
    }

    @Test
    func parameterOverrides() throws {
        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .expression(.identifier("rval"))]
                )
            ],
            parameters: ["rval": .literal(1000)]
        )

        // Use configuration with parameter override
        let config = NetlistLowering.Configuration(
            parameterOverrides: ["rval": 5000]
        )
        let lowering = NetlistLowering(configuration: config)
        let circuit = try lowering.lower(netlist)

        #expect(circuit.instances.count == 1)
        if case .real(let r) = circuit.instances[0].parameters["r"] {
            #expect(r == 5000.0) // Override takes precedence
        }
    }

    @Test
    func customTemperature() throws {
        let config = NetlistLowering.Configuration(temperature: 85.0)
        let lowering = NetlistLowering(configuration: config)

        let netlist = ParsedNetlist(
            components: [
                ParsedComponent(
                    name: "R1",
                    type: .resistor,
                    nodes: ["in", "out"],
                    parameters: ["r": .numeric(1000)]
                )
            ]
        )

        // Just verify it doesn't throw - temperature is set in context
        let circuit = try lowering.lower(netlist)
        #expect(circuit.instances.count == 1)
    }

    @Test
    func customMaxDepth() {
        let config = NetlistLowering.Configuration(maxExpansionDepth: 10)
        #expect(config.maxExpansionDepth == 10)
    }
}
