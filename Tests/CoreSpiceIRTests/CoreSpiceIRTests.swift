import Testing
@testable import CoreSpiceIR

@Suite("CoreSpiceIR Tests")
struct CoreSpiceIRTests {

    @Test func groundNodeIsZero() {
        #expect(Node.ground.id == 0)
    }

    @Test func nodeEquality() {
        let n1 = Node(id: 1)
        let n2 = Node(id: 1)
        let n3 = Node(id: 2)
        #expect(n1 == n2)
        #expect(n1 != n3)
    }

    @Test func branchCreation() {
        let b = Branch(id: 0)
        #expect(b.id == 0)
    }

    @Test func portCreation() {
        let p = Port(name: "drain", index: 0)
        #expect(p.name == "drain")
        #expect(p.index == 0)
    }

    @Test func netlistBuildsCircuitIR() throws {
        var netlist = Netlist()
        let n1 = netlist.node("1")
        let n2 = netlist.node("2")
        #expect(n1.id != 0)
        #expect(n2.id != 0)
        #expect(n1 != n2)

        try netlist.addInstance(
            name: "R1", typeName: "resistor",
            nodes: ["1", "2"],
            parameters: ["r": .real(1000)]
        )

        let ir = try netlist.build()
        #expect(ir.instances.count == 1)
        #expect(ir.instances[0].name == "R1")
        #expect(ir.instances[0].typeName == "resistor")
        #expect(ir.name(for: n1) == "1")
        #expect(ir.name(for: n2) == "2")
        #expect(ir.name(for: .ground) == "0")
    }

    @Test func netlistBuildsCircuitIRWithBranchNames() throws {
        var netlist = Netlist()
        let branch = netlist.branch(name: "VDD")
        try netlist.addInstance(
            name: "VDD",
            typeName: "vsource",
            nodes: ["vdd", "0"],
            parameters: ["v": .real(1.8)]
        )

        let ir = try netlist.build()

        #expect(ir.name(for: branch) == "VDD")
        #expect(ir.branches == [branch])
    }

    @Test func netlistRejectsDuplicateNames() throws {
        var netlist = Netlist()
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                                parameters: ["r": .real(100)])
        #expect(throws: NetlistError.self) {
            try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["2", "0"],
                                    parameters: ["r": .real(200)])
        }
    }

    @Test func emptyNetlistThrows() {
        let netlist = Netlist()
        #expect(throws: NetlistError.self) {
            try netlist.build()
        }
    }

    @Test func circuitTopologyAssignsIndices() throws {
        var netlist = Netlist()
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["1", "0"],
                                parameters: ["v": .real(5)])
        let ir = try netlist.build()
        let topo = CircuitTopology(ir: ir)

        // Nodes 1 and 2 should have indices (ground excluded)
        #expect(topo.nodeCount >= 2)
        #expect(topo.matrixSize >= 2)
    }

    @Test func mnaVariableHashable() {
        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let b = Branch(id: 0)
        let v1: MNAVariable = .nodeVoltage(n1)
        let v2: MNAVariable = .nodeVoltage(n2)
        let i1: MNAVariable = .branchCurrent(b)
        #expect(v1 != v2)
        #expect(v1 != i1)

        var set: Set<MNAVariable> = [v1, v2, i1]
        #expect(set.count == 3)
        set.insert(v1)
        #expect(set.count == 3)
    }

    @Test func parameterValueVariants() {
        let r = ParameterValue.real(1000)
        let i = ParameterValue.integer(5)
        let s = ParameterValue.string("hello")
        let c = ParameterValue.complex(ComplexValue(real: 1, imag: 2))

        if case .real(let v) = r { #expect(v == 1000) }
        if case .integer(let v) = i { #expect(v == 5) }
        if case .string(let v) = s { #expect(v == "hello") }
        if case .complex(let v) = c {
            #expect(v.real == 1)
            #expect(v.imag == 2)
        }
    }
}
