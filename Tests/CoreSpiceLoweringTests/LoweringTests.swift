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
