import Testing
@testable import CoreSpiceParsedIR

@Suite
struct ParsedExpressionTests {

    @Test
    func literalExpression() {
        let expr = ParsedExpression.literal(42.0)
        #expect(expr == .literal(42.0))
        #expect(expr.description == "42.0")
    }

    @Test
    func identifierExpression() {
        let expr = ParsedExpression.identifier("vdd")
        #expect(expr == .identifier("vdd"))
        #expect(expr.description == "vdd")
    }

    @Test
    func unaryExpression() {
        let inner = ParsedExpression.literal(5.0)
        let expr = ParsedExpression.unaryOperation(.negate, inner)
        #expect(expr.description == "(-5.0)")
    }

    @Test
    func binaryExpression() {
        let lhs = ParsedExpression.literal(2.0)
        let rhs = ParsedExpression.literal(3.0)
        let expr = ParsedExpression.binaryOperation(.multiply, lhs, rhs)
        #expect(expr.description == "(2.0 * 3.0)")
    }

    @Test
    func functionCallExpression() {
        let arg = ParsedExpression.literal(0.5)
        let expr = ParsedExpression.functionCall(name: "sin", arguments: [arg])
        #expect(expr.description == "sin(0.5)")
    }

    @Test
    func conditionalExpression() {
        let cond = ParsedExpression.identifier("flag")
        let then = ParsedExpression.literal(1.0)
        let `else` = ParsedExpression.literal(0.0)
        let expr = ParsedExpression.conditional(condition: cond, then: then, else: `else`)
        #expect(expr.description.contains("?"))
    }
}

@Suite
struct ParsedParameterValueTests {

    @Test
    func numericValue() {
        let value = ParsedParameterValue.numeric(1000.0)
        #expect(value == .numeric(1000.0))
    }

    @Test
    func stringValue() {
        let value = ParsedParameterValue.string("model_name")
        #expect(value == .string("model_name"))
    }

    @Test
    func expressibleByLiterals() {
        let numeric: ParsedParameterValue = 42.5
        #expect(numeric == .numeric(42.5))

        let str: ParsedParameterValue = "test"
        #expect(str == .string("test"))

        let boolean: ParsedParameterValue = true
        #expect(boolean == .boolean(true))
    }
}

@Suite
struct SourceLocationTests {

    @Test
    func basicLocation() {
        let loc = SourceLocation(file: "test.sp", line: 10, column: 5)
        #expect(loc.file == "test.sp")
        #expect(loc.line == 10)
        #expect(loc.column == 5)
        #expect(loc.description == "test.sp:10:5")
    }

    @Test
    func unknownLocation() {
        let loc = SourceLocation.unknown(line: 1, column: 1)
        #expect(loc.file == "<unknown>")
    }
}

@Suite
struct ParsedComponentTests {

    @Test
    func resistorComponent() {
        let component = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["in", "out"],
            parameters: ["r": .numeric(1000)]
        )

        #expect(component.name == "R1")
        #expect(component.type == .resistor)
        #expect(component.nodes.count == 2)
        #expect(component.parameters["r"] == .numeric(1000))
    }

    @Test
    func mosfetComponent() {
        let component = ParsedComponent(
            name: "M1",
            type: .mosfet,
            nodes: ["d", "g", "s", "b"],
            modelName: "nch",
            parameters: ["w": .numeric(1e-6), "l": .numeric(100e-9)]
        )

        #expect(component.type == .mosfet)
        #expect(component.nodes.count == 4)
        #expect(component.modelName == "nch")
    }

    @Test
    func subcircuitInstance() {
        let component = ParsedComponent(
            name: "X1",
            type: .subcircuitInstance,
            nodes: ["in", "out", "vdd", "vss"],
            modelName: "inv"
        )

        #expect(component.type == .subcircuitInstance)
        #expect(component.modelName == "inv")
    }
}

@Suite
struct ParsedSubcircuitTests {

    @Test
    func basicSubcircuit() {
        let resistor = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["in", "out"],
            parameters: ["r": .numeric(1000)]
        )

        let subcircuit = ParsedSubcircuit(
            name: "load",
            ports: ["in", "out"],
            body: ParsedNetlistBody(components: [resistor])
        )

        #expect(subcircuit.name == "load")
        #expect(subcircuit.ports == ["in", "out"])
        #expect(subcircuit.body.components.count == 1)
    }

    @Test
    func subcircuitWithParameters() {
        let subcircuit = ParsedSubcircuit(
            name: "res",
            ports: ["p", "n"],
            parameters: ["rval": .numeric(1000)],
            body: ParsedNetlistBody()
        )

        #expect(subcircuit.parameters["rval"] == .numeric(1000))
    }
}

@Suite
struct ParsedNodeRefTests {

    @Test
    func namedNode() {
        let ref: ParsedNodeRef = "vdd"
        #expect(ref.name == "vdd")
    }

    @Test
    func groundNode() {
        let ref: ParsedNodeRef = "0"
        #expect(ref.isGround)
    }

    @Test
    func gndAlias() {
        let ref: ParsedNodeRef = "gnd"
        #expect(ref.isGround)
    }

    @Test
    func nonGroundNode() {
        let ref: ParsedNodeRef = "vdd"
        #expect(!ref.isGround)
    }
}

@Suite
struct ParsedNetlistTests {

    @Test
    func emptyNetlist() {
        let netlist = ParsedNetlist()
        #expect(netlist.components.isEmpty)
        #expect(netlist.models.isEmpty)
        #expect(netlist.subcircuits.isEmpty)
    }

    @Test
    func netlistWithComponents() {
        let r1 = ParsedComponent(
            name: "R1",
            type: .resistor,
            nodes: ["a", "b"],
            parameters: ["r": .numeric(1000)]
        )
        let r2 = ParsedComponent(
            name: "R2",
            type: .resistor,
            nodes: ["b", "0"],
            parameters: ["r": .numeric(2000)]
        )

        let netlist = ParsedNetlist(
            title: "Test Circuit",
            components: [r1, r2]
        )

        #expect(netlist.title == "Test Circuit")
        #expect(netlist.components.count == 2)
    }

    @Test
    func netlistWithModels() {
        let model = ParsedModel(
            name: "nch",
            type: .nmos,
            level: 1,
            parameters: ["vth": .numeric(0.5)]
        )

        let netlist = ParsedNetlist(models: [model])
        #expect(netlist.models.count == 1)
        #expect(netlist.models.first?.name == "nch")
    }
}

@Suite
struct ComponentTypeTests {

    @Test
    func basicComponents() {
        #expect(ComponentType.resistor != .capacitor)
        #expect(ComponentType.inductor != .resistor)
    }

    @Test
    func voltageSourceType() {
        #expect(ComponentType.voltageSource == .voltageSource)
        #expect(ComponentType.voltageSource.rawValue == "V")
    }

    @Test
    func subcircuitInstanceType() {
        #expect(ComponentType.subcircuitInstance == .subcircuitInstance)
        #expect(ComponentType.subcircuitInstance.rawValue == "X")
    }

    @Test
    func nodeCount() {
        #expect(ComponentType.resistor.standardNodeCount == 2)
        #expect(ComponentType.mosfet.standardNodeCount == 4)
        #expect(ComponentType.bjt.standardNodeCount == 3)
        #expect(ComponentType.subcircuitInstance.standardNodeCount == nil)
    }
}

@Suite
struct ModelTypeTests {

    @Test
    func mosTypes() {
        #expect(ModelType.nmos != .pmos)
    }

    @Test
    func bjtTypes() {
        #expect(ModelType.npn != .pnp)
    }

    @Test
    func diodeType() {
        #expect(ModelType.diode == .diode)
    }
}
