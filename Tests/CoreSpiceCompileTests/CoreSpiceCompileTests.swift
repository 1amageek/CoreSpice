import Testing
import Foundation
@testable import CoreSpiceCompile
@testable import CoreSpiceIR

@Suite("CoreSpiceCompile Tests")
struct CoreSpiceCompileTests {

    @Test func sparseStructureFromTriplets() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1), (2, 2)]
        )
        #expect(structure.dimension == 3)
        #expect(structure.nonZeroCount == 5)
        #expect(structure.index(row: 0, col: 0) != nil)
        #expect(structure.index(row: 0, col: 1) != nil)
        #expect(structure.index(row: 0, col: 2) == nil)
        #expect(structure.index(row: 2, col: 2) != nil)
    }

    @Test func sparseStructureRejectsMalformedCSR() {
        #expect(throws: SparseStructureError.rowPointerCount(expected: 3, actual: 2)) {
            _ = try SparseStructure(
                dimension: 2,
                rowPointers: [0, 1],
                columnIndices: [0]
            )
        }
        #expect(
            throws: SparseStructureError.columnsNotStrictlyIncreasing(
                row: 0,
                previous: 1,
                current: 0
            )
        ) {
            _ = try SparseStructure(
                dimension: 2,
                rowPointers: [0, 2, 2],
                columnIndices: [1, 0]
            )
        }
    }

    @Test func sparseStructureRejectsOutOfBoundsTriplet() {
        #expect(
            throws: SparseStructureError.tripletOutOfBounds(
                row: 2,
                column: 0,
                dimension: 2
            )
        ) {
            _ = try SparseStructure.fromTriplets(
                dimension: 2,
                entries: [(row: 2, col: 0)]
            )
        }
    }

    @Test func sparseMatrixAddAndRetrieve() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 2.0)
        matrix.addValue(row: 0, col: 1, value: -1.0)
        matrix.addValue(row: 1, col: 0, value: -1.0)
        matrix.addValue(row: 1, col: 1, value: 2.0)

        #expect(matrix.value(row: 0, col: 0) == 2.0)
        #expect(matrix.value(row: 0, col: 1) == -1.0)
        #expect(matrix.value(row: 1, col: 1) == 2.0)
    }

    @Test func sparseMatrixClear() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (1, 1)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 5.0)
        matrix.clear()
        #expect(matrix.value(row: 0, col: 0) == 0.0)
    }

    @Test func sparseMatrixMultiply() throws {
        // [2 -1] * [1] = [1]
        // [-1 2]   [1]   [1]
        let structure = try SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 2.0)
        matrix.addValue(row: 0, col: 1, value: -1.0)
        matrix.addValue(row: 1, col: 0, value: -1.0)
        matrix.addValue(row: 1, col: 1, value: 2.0)

        let result = try matrix.multiply(vector: [1.0, 1.0])
        #expect(abs(result[0] - 1.0) < 1e-10)
        #expect(abs(result[1] - 1.0) < 1e-10)
    }

    @Test func sparseMatrixCheckedMultiplyRejectsShapeMismatch() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (1, 1)]
        )
        let matrix = SparseMatrix(structure: structure)

        #expect(throws: SparseMatrixError.vectorLengthMismatch(expected: 2, actual: 1)) {
            _ = try matrix.checkedMultiply(vector: [1.0])
        }

        var result = [0.0]
        #expect(throws: SparseMatrixError.resultLengthMismatch(expected: 2, actual: 1)) {
            try matrix.checkedMultiply(vector: [1.0, 2.0], into: &result)
        }
    }

    @Test func complexSparseMatrixCheckedMultiplyRejectsShapeMismatch() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (1, 1)]
        )
        let matrix = ComplexSparseMatrix(structure: structure)

        #expect(throws: SparseMatrixError.vectorLengthMismatch(expected: 2, actual: 1)) {
            _ = try matrix.checkedMultiply(vector: [ComplexPair.one])
        }

        var result = [ComplexPair.zero]
        #expect(throws: SparseMatrixError.resultLengthMismatch(expected: 2, actual: 1)) {
            try matrix.checkedMultiply(vector: [ComplexPair.one, ComplexPair.one], into: &result)
        }
    }

    @Test func luSolverSimple2x2() throws {
        // Solve: [2 1] [x] = [5]
        //        [1 3] [y]   [7]
        // Solution: x=8/5=1.6, y=9/5=1.8
        let structure = try SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 2.0)
        matrix.addValue(row: 0, col: 1, value: 1.0)
        matrix.addValue(row: 1, col: 0, value: 1.0)
        matrix.addValue(row: 1, col: 1, value: 3.0)

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [5.0, 7.0])

        #expect(abs(x[0] - 1.6) < 1e-10)
        #expect(abs(x[1] - 1.8) < 1e-10)
    }

    @Test func luSolver3x3WithPivoting() throws {
        // [0  2  1] [x]   [1]
        // [1 -1  0] [y] = [2]
        // [2  1 -1] [z]   [3]
        let structure = try SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0,0),(0,1),(0,2),(1,0),(1,1),(1,2),(2,0),(2,1),(2,2)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 0.0)
        matrix.addValue(row: 0, col: 1, value: 2.0)
        matrix.addValue(row: 0, col: 2, value: 1.0)
        matrix.addValue(row: 1, col: 0, value: 1.0)
        matrix.addValue(row: 1, col: 1, value: -1.0)
        matrix.addValue(row: 1, col: 2, value: 0.0)
        matrix.addValue(row: 2, col: 0, value: 2.0)
        matrix.addValue(row: 2, col: 1, value: 1.0)
        matrix.addValue(row: 2, col: 2, value: -1.0)

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [1.0, 2.0, 3.0])

        // Verify A*x = b
        var result = try matrix.multiply(vector: x)
        #expect(abs(result[0] - 1.0) < 1e-10)
        #expect(abs(result[1] - 2.0) < 1e-10)
        #expect(abs(result[2] - 3.0) < 1e-10)
    }

    @Test func complexPairArithmetic() throws {
        let a = ComplexPair(real: 1, imag: 2)
        let b = ComplexPair(real: 3, imag: -1)

        let sum = a + b
        #expect(abs(sum.real - 4.0) < 1e-10)
        #expect(abs(sum.imag - 1.0) < 1e-10)

        let diff = a - b
        #expect(abs(diff.real - (-2.0)) < 1e-10)
        #expect(abs(diff.imag - 3.0) < 1e-10)

        // (1+2i)(3-i) = 3-i+6i-2i² = 3+5i+2 = 5+5i
        let prod = a * b
        #expect(abs(prod.real - 5.0) < 1e-10)
        #expect(abs(prod.imag - 5.0) < 1e-10)

        #expect(abs(a.magnitude - sqrt(5.0)) < 1e-10)
    }

    @Test func complexLUSolver() throws {
        // Solve (1+i)x = 2+0i => x = 2/(1+i) = 1-i
        let structure = try SparseStructure.fromTriplets(dimension: 1, entries: [(0, 0)])
        var matrix = ComplexSparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: ComplexPair(real: 1, imag: 1))

        var solver = ComplexSparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [ComplexPair(real: 2, imag: 0)])

        #expect(abs(x[0].real - 1.0) < 1e-10)
        #expect(abs(x[0].imag - (-1.0)) < 1e-10)
    }

    @Test func matrixTopologyCreation() throws {
        var netlist = Netlist()
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "2"],
                                parameters: ["r": .real(1000)])
        let ir = try netlist.build()
        let topo = MatrixTopology(ir: ir)

        #expect(topo.dimension >= 2)
        let n1 = ir.nodes.first { $0.id != 0 }!
        #expect(topo.nodeIndex(n1) != nil)
        #expect(topo.nodeIndex(.ground) == nil)
    }

    @Test func opticalMatrixTopologyIncludesElectricalSensitivityCouplings() throws {
        var netlist = Netlist()
        let laserAnode = netlist.node("laser_a")
        let photodiodeAnode = netlist.node("pd_a")
        try netlist.addInstance(
            name: "LD1",
            typeName: "laser",
            nodes: ["laser_a", "0"],
            opticalNodes: ["opt_out"],
            parameters: [:]
        )
        try netlist.addInstance(
            name: "PD1",
            typeName: "photodiode",
            nodes: ["pd_a", "0"],
            opticalNodes: ["opt_out"],
            parameters: [:]
        )

        let ir = try netlist.build()
        let topology = MatrixTopology(ir: ir)

        let laserIndex = topology.variableMap[.nodeVoltage(laserAnode)]
        let photodiodeIndex = topology.variableMap[.nodeVoltage(photodiodeAnode)]

        #expect(laserIndex != nil)
        #expect(photodiodeIndex != nil)
        if let laserIndex, let photodiodeIndex {
            #expect(topology.structure.index(row: photodiodeIndex, col: laserIndex) != nil)
        }
    }

    @Test func standardCompiler() throws {
        var netlist = Netlist()
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["1", "0"],
                                parameters: ["r": .real(1000)])
        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        #expect(plan.deviceNames.count == 1)
        #expect(plan.deviceNames[0] == "R1")
    }

    @Test("PEX-scale branch topology remains locally sparse")
    func pexScaleBranchTopologyIsLinear() {
        let deviceCount = 1_000
        let nodes = (1...deviceCount).map(Node.init(id:))
        let branches = (0..<deviceCount).map(Branch.init(id:))
        let instances = (0..<deviceCount).map { index in
            Instance(
                name: "V\(index)",
                typeName: "vsource",
                nodes: [nodes[index], .ground],
                parameters: ["v": .real(0)],
                ownedBranches: [branches[index]]
            )
        }
        let topology = MatrixTopology(
            ir: CircuitIR(
                nodes: [.ground] + nodes,
                branches: branches,
                instances: instances
            )
        )

        #expect(topology.dimension == deviceCount * 2)
        #expect(topology.structure.nonZeroCount == deviceCount * 4)
    }

    @Test("Referenced branch connectivity includes only the local dependency")
    func referencedBranchConnectivityIsExplicit() {
        let sourceNode = Node(id: 1)
        let outputNode = Node(id: 2)
        let sourceBranch = Branch(id: 0)
        let outputBranch = Branch(id: 1)
        let topology = MatrixTopology(
            ir: CircuitIR(
                nodes: [.ground, sourceNode, outputNode],
                branches: [sourceBranch, outputBranch],
                instances: [
                    Instance(
                        name: "V1",
                        typeName: "vsource",
                        nodes: [sourceNode, .ground],
                        parameters: ["v": .real(1)],
                        ownedBranches: [sourceBranch]
                    ),
                    Instance(
                        name: "H1",
                        typeName: "ccvs_ref",
                        nodes: [outputNode, .ground],
                        parameters: ["h": .real(1)],
                        ownedBranches: [outputBranch],
                        referencedBranches: [sourceBranch]
                    ),
                ]
            )
        )
        let sourceIndex = topology.variableMap[.branchCurrent(sourceBranch)]
        let outputIndex = topology.variableMap[.branchCurrent(outputBranch)]

        #expect(sourceIndex != nil)
        #expect(outputIndex != nil)
        if let sourceIndex, let outputIndex {
            #expect(topology.structure.index(row: outputIndex, col: sourceIndex) != nil)
            #expect(topology.structure.index(row: sourceIndex, col: outputIndex) != nil)
        }
    }
}
