import Testing
@testable import CoreSpiceIR

@Suite("IR Validation Tests")
struct ValidationTests {

    // MARK: - Ground Connection Tests

    @Test func circuitWithGroundPasses() throws {
        var netlist = Netlist()
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "0"],
            parameters: ["r": .real(1000)]
        )
        let ir = try netlist.build()
        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(result.isValid)
        #expect(!result.errors.contains(.noGroundConnection))
    }

    @Test func circuitWithGndNodePasses() throws {
        var netlist = Netlist()
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "gnd"],
            parameters: ["r": .real(1000)]
        )
        let ir = try netlist.build()
        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(result.isValid)
    }

    @Test func circuitWithoutGroundFails() throws {
        // Manually create an IR without ground connection
        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let instance = Instance(
            name: "R1",
            typeName: "resistor",
            nodes: [n1, n2],
            parameters: ["r": .real(1000)]
        )
        let ir = CircuitIR(nodes: [n1, n2], branches: [], instances: [instance])

        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(!result.isValid)
        #expect(result.errors.contains(.noGroundConnection))
    }

    // MARK: - Self-Loop Tests

    @Test func selfLoopDetected() throws {
        // Create an instance with both terminals on the same node
        let n1 = Node(id: 1)
        let instance = Instance(
            name: "R1",
            typeName: "resistor",
            nodes: [n1, n1],
            parameters: ["r": .real(1000)]
        )
        let ir = CircuitIR(nodes: [.ground, n1], branches: [], instances: [instance])

        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(!result.isValid)
        #expect(result.errors.contains(.selfLoop(device: "R1")))
    }

    @Test func noSelfLoopForDifferentNodes() throws {
        var netlist = Netlist()
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "0"],
            parameters: ["r": .real(1000)]
        )
        let ir = try netlist.build()
        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(!result.errors.contains(where: {
            if case .selfLoop = $0 { return true }
            return false
        }))
    }

    // MARK: - Floating Subcircuit Tests

    @Test func connectedCircuitPasses() throws {
        var netlist = Netlist()
        // Create a connected circuit: V1 -- R1 -- R2 -- ground
        try netlist.addInstance(
            name: "V1",
            typeName: "vsource",
            nodes: ["1", "0"],
            parameters: ["v": .real(5)]
        )
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "2"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2",
            typeName: "resistor",
            nodes: ["2", "0"],
            parameters: ["r": .real(1000)]
        )
        let ir = try netlist.build()
        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(result.isValid)
        #expect(!result.errors.contains(where: {
            if case .floatingSubcircuit = $0 { return true }
            return false
        }))
    }

    @Test func floatingSubcircuitDetected() throws {
        // Create two disconnected components
        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let n3 = Node(id: 3)
        let n4 = Node(id: 4)

        let r1 = Instance(
            name: "R1",
            typeName: "resistor",
            nodes: [.ground, n1],
            parameters: ["r": .real(1000)]
        )
        let r2 = Instance(
            name: "R2",
            typeName: "resistor",
            nodes: [n1, n2],
            parameters: ["r": .real(1000)]
        )
        // Disconnected from ground
        let r3 = Instance(
            name: "R3",
            typeName: "resistor",
            nodes: [n3, n4],
            parameters: ["r": .real(1000)]
        )

        let ir = CircuitIR(
            nodes: [.ground, n1, n2, n3, n4],
            branches: [],
            instances: [r1, r2, r3]
        )

        let validator = IRValidator()
        let result = validator.validate(ir)
        #expect(!result.isValid)
        #expect(result.errors.contains(.floatingSubcircuit(componentCount: 2)))
    }

    // MARK: - Dangling Node Warnings

    @Test func orphanedNodeWarning() throws {
        // Create IR with a defined node that's not used
        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let n3 = Node(id: 3)  // orphaned

        let r1 = Instance(
            name: "R1",
            typeName: "resistor",
            nodes: [.ground, n1],
            parameters: ["r": .real(1000)]
        )
        let r2 = Instance(
            name: "R2",
            typeName: "resistor",
            nodes: [n1, n2],
            parameters: ["r": .real(1000)]
        )

        let ir = CircuitIR(
            nodes: [.ground, n1, n2, n3],
            branches: [],
            instances: [r1, r2]
        )

        let validator = IRValidator()
        let result = validator.validate(ir)
        // Still valid (orphaned nodes are warnings, not errors)
        #expect(result.warnings.contains(.danglingNode(nodeId: 3)))
    }

    // MARK: - Netlist Parameter Validation

    @Test func emptyInstanceNameThrows() {
        var netlist = Netlist()
        #expect(throws: NetlistError.self) {
            try netlist.addInstance(
                name: "",
                typeName: "resistor",
                nodes: ["1", "0"],
                parameters: ["r": .real(1000)]
            )
        }
    }

    @Test func emptyNodeNameThrows() {
        var netlist = Netlist()
        #expect(throws: NetlistError.self) {
            try netlist.addInstance(
                name: "R1",
                typeName: "resistor",
                nodes: ["1", ""],
                parameters: ["r": .real(1000)]
            )
        }
    }

    @Test func infiniteParameterThrows() {
        var netlist = Netlist()
        #expect(throws: NetlistError.self) {
            try netlist.addInstance(
                name: "R1",
                typeName: "resistor",
                nodes: ["1", "0"],
                parameters: ["r": .real(Double.infinity)]
            )
        }
    }

    @Test func nanParameterThrows() {
        var netlist = Netlist()
        #expect(throws: NetlistError.self) {
            try netlist.addInstance(
                name: "R1",
                typeName: "resistor",
                nodes: ["1", "0"],
                parameters: ["r": .real(Double.nan)]
            )
        }
    }

    @Test func validParameterPasses() throws {
        var netlist = Netlist()
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "0"],
            parameters: ["r": .real(1000)]
        )
        let ir = try netlist.build()
        #expect(ir.instances.count == 1)
    }

    // MARK: - Build and Validate Integration

    @Test func buildAndValidateReturnsWarnings() throws {
        var netlist = Netlist()
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "0"],
            parameters: ["r": .real(1000)]
        )
        let (ir, warnings) = try netlist.buildAndValidate()
        #expect(ir.instances.count == 1)
        // May or may not have warnings depending on the circuit
        _ = warnings
    }

    @Test func buildAndValidateThrowsOnError() throws {
        // Create a netlist that will produce an IR with errors
        // We need to bypass normal validation in addInstance
        var netlist = Netlist()
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["1", "2"],  // Neither connects to ground
            parameters: ["r": .real(1000)]
        )

        // This should throw because there's no ground connection
        #expect(throws: NetlistError.self) {
            try netlist.buildAndValidate()
        }
    }

    // MARK: - IRValidationError Equatable Tests

    @Test func validationErrorEquality() {
        let e1 = IRValidationError.noGroundConnection
        let e2 = IRValidationError.noGroundConnection
        #expect(e1 == e2)

        let e3 = IRValidationError.selfLoop(device: "R1")
        let e4 = IRValidationError.selfLoop(device: "R1")
        let e5 = IRValidationError.selfLoop(device: "R2")
        #expect(e3 == e4)
        #expect(e3 != e5)

        let e6 = IRValidationError.floatingSubcircuit(componentCount: 2)
        let e7 = IRValidationError.floatingSubcircuit(componentCount: 2)
        let e8 = IRValidationError.floatingSubcircuit(componentCount: 3)
        #expect(e6 == e7)
        #expect(e6 != e8)
    }

    // MARK: - IRValidationWarning Equatable Tests

    @Test func validationWarningEquality() {
        let w1 = IRValidationWarning.danglingNode(nodeId: 1)
        let w2 = IRValidationWarning.danglingNode(nodeId: 1)
        let w3 = IRValidationWarning.danglingNode(nodeId: 2)
        #expect(w1 == w2)
        #expect(w1 != w3)

        let w4 = IRValidationWarning.unusedBranch(branchId: 0)
        let w5 = IRValidationWarning.unusedBranch(branchId: 0)
        #expect(w4 == w5)
    }

    // MARK: - Complex Circuit Validation

    @Test func complexValidCircuit() throws {
        var netlist = Netlist()

        // Create a more complex circuit: voltage divider with multiple branches
        try netlist.addInstance(
            name: "V1",
            typeName: "vsource",
            nodes: ["vcc", "0"],
            parameters: ["v": .real(12)]
        )
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["vcc", "mid"],
            parameters: ["r": .real(10000)]
        )
        try netlist.addInstance(
            name: "R2",
            typeName: "resistor",
            nodes: ["mid", "0"],
            parameters: ["r": .real(10000)]
        )
        try netlist.addInstance(
            name: "R3",
            typeName: "resistor",
            nodes: ["mid", "out"],
            parameters: ["r": .real(5000)]
        )
        try netlist.addInstance(
            name: "R4",
            typeName: "resistor",
            nodes: ["out", "0"],
            parameters: ["r": .real(5000)]
        )

        let (ir, warnings) = try netlist.buildAndValidate()
        #expect(ir.instances.count == 5)
        #expect(warnings.isEmpty)
    }

    @Test func threeTerminalDeviceWithSameNode() throws {
        // Test 3-terminal device with two terminals on same node (partial self-loop)
        let n1 = Node(id: 1)
        let n2 = Node(id: 2)

        // A transistor with collector and base on same node (unusual but detectable)
        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [n1, n1, n2],  // collector and base same
            parameters: [:]
        )
        let ir = CircuitIR(
            nodes: [.ground, n1, n2],
            branches: [],
            instances: [instance]
        )

        let validator = IRValidator()
        let result = validator.validate(ir)
        // Should detect self-loop (same node appears twice)
        #expect(result.errors.contains(.selfLoop(device: "Q1")))
    }
}
