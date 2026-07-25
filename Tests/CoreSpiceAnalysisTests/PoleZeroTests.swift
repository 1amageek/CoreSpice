import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Pole-Zero Analysis Tests")
struct PoleZeroTests {

    @Test("Generalized eigen solver rejects malformed and non-finite matrices")
    func generalizedEigenSolverValidatesInputs() {
        #expect(
            throws: GeneralizedEigenSolver.EigenSolverError.matrixSizeMismatch(
                expected: 4,
                matrixA: 1,
                matrixB: 4
            )
        ) {
            _ = try GeneralizedEigenSolver.solve(
                matrixA: [1],
                matrixB: [1, 0, 0, 1],
                dimension: 2
            )
        }
        do {
            _ = try GeneralizedEigenSolver.solve(
                matrixA: [.nan],
                matrixB: [1],
                dimension: 1
            )
            Issue.record("Expected a non-finite matrix failure.")
        } catch GeneralizedEigenSolver.EigenSolverError.nonFiniteMatrixValue(
            let matrix,
            let index,
            let value
        ) {
            #expect(matrix == "A")
            #expect(index == 0)
            #expect(value.isNaN)
        } catch {
            Issue.record("Unexpected eigen solver error: \(error)")
        }
    }

    /// RC lowpass filter: V1 → R(1kΩ) → out → C(1µF) → GND
    ///
    /// Transfer function: H(s) = 1 / (1 + sRC)
    /// Expected pole: s = -1/(RC) = -1000 rad/s
    /// DC gain: 1.0 (capacitor is open at DC)
    @Test func rcLowpassPole() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "C1", typeName: "capacitor", nodes: ["out", "0"],
            parameters: ["c": .real(1e-6)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let pzAnalysis = PoleZeroAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await pzAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // One finite pole expected
        #expect(result.poles.count == 1)

        // Pole at s ≈ -1/(RC) = -1/(1000 × 1e-6) = -1000 rad/s
        let pole = result.poles[0]
        let expectedPoleReal = -1.0 / (1000.0 * 1e-6)
        #expect(abs(pole.real - expectedPoleReal) < abs(expectedPoleReal) * 0.01)
        #expect(abs(pole.imag) < 1.0)

        // DC gain = 1.0
        #expect(abs(result.dcGain - 1.0) < 0.01)
    }

    /// RLC series circuit: V1 → R(10Ω) → L(1mH) → out → C(1µF) → GND
    ///
    /// Transfer function across C: H(s) = 1 / (s²LC + sRC + 1)
    /// With R=10, L=1e-3, C=1e-6:
    ///   ω_n = 1/√(LC) = 31623 rad/s
    ///   ζ = R/(2√(L/C)) = 0.158
    ///   Poles: s = -ζω_n ± jω_n√(1-ζ²) ≈ -5000 ± j31225
    @Test func rlcConjugatePoles() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("mid")
        let out = netlist.node("out")
        let _ = netlist.branch()  // V1
        let _ = netlist.branch()  // L1

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "mid"],
            parameters: ["r": .real(10)]
        )
        try netlist.addInstance(
            name: "L1", typeName: "inductor", nodes: ["mid", "out"],
            parameters: ["l": .real(1e-3)]
        )
        try netlist.addInstance(
            name: "C1", typeName: "capacitor", nodes: ["out", "0"],
            parameters: ["c": .real(1e-6)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let pzAnalysis = PoleZeroAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await pzAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Two finite poles (conjugate pair)
        #expect(result.poles.count == 2)

        // Expected: s ≈ -5000 ± j31225
        let r = 10.0
        let l = 1e-3
        let c = 1e-6
        let omegaN = 1.0 / (l * c).squareRoot()
        let zeta = r / (2.0 * (l / c).squareRoot())
        let expectedReal = -zeta * omegaN
        let expectedImag = omegaN * (1.0 - zeta * zeta).squareRoot()

        // Sort poles by imaginary part
        let sortedPoles = result.poles.sorted { $0.imag < $1.imag }

        // Both poles should have real part ≈ -5000
        for pole in sortedPoles {
            #expect(abs(pole.real - expectedReal) < abs(expectedReal) * 0.05)
        }

        // Imaginary parts should be conjugate: ≈ ±31225
        #expect(abs(sortedPoles[0].imag - (-expectedImag)) < expectedImag * 0.05)
        #expect(abs(sortedPoles[1].imag - expectedImag) < expectedImag * 0.05)

        // DC gain = 1.0 (L is short, C is open at DC)
        #expect(abs(result.dcGain - 1.0) < 0.01)
    }

    /// All poles of a passive RC/RLC circuit must have negative real parts.
    @Test func stablePolesNegativeReal() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(1.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "C1", typeName: "capacitor", nodes: ["out", "0"],
            parameters: ["c": .real(1e-6)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        let pzAnalysis = PoleZeroAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await pzAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // All poles of a passive circuit must have negative real parts
        for pole in result.poles {
            #expect(pole.real < 0)
        }
    }
}
