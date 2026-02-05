import Testing
import Synchronization
import Foundation
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceEvent

/// Thread-safe collector for complex matrix stamp entries.
private final class DiodeComplexStampCollector: Sendable {
    private let _matrix = Mutex<[(Int, Int, Double, Double)]>([])  // (row, col, real, imag)

    func addMatrix(_ r: Int, _ c: Int, _ re: Double, _ im: Double) {
        _matrix.withLock { $0.append((r, c, re, im)) }
    }
    var entries: [(Int, Int, Double, Double)] { _matrix.withLock { $0 } }

    func imaginarySum(row: Int, col: Int) -> Double {
        entries.filter { $0.0 == row && $0.1 == col }.map { $0.3 }.reduce(0, +)
    }
    func realSum(row: Int, col: Int) -> Double {
        entries.filter { $0.0 == row && $0.1 == col }.map { $0.2 }.reduce(0, +)
    }
    func reset() {
        _matrix.withLock { $0.removeAll() }
    }
}

/// Unit tests for diode junction capacitance model.
///
/// Verifies the voltage-dependent junction capacitance:
/// 1. Zero bias capacitance: Cj(0) = Cjo
/// 2. Reverse bias: Cj = Cjo / (1 - V/Vj)^m
/// 3. Forward bias linear extrapolation to avoid singularity
/// 4. Diffusion capacitance: Cd = τ × gd
@Suite("Diode Junction Capacitance Tests")
struct DiodeJunctionCapacitanceTests {

    // MARK: - Test Constants

    let cjo: Double = 10e-12       // 10 pF zero-bias capacitance
    let vj: Double = 0.7           // Built-in potential
    let m: Double = 0.5            // Grading coefficient
    let transitTime: Double = 1e-9 // 1 ns transit time
    let isat: Double = 1e-14       // Saturation current

    // MARK: - Test 1: Zero Bias Junction Capacitance

    /// Verifies that at zero bias, Cj = Cjo.
    ///
    /// Mathematical basis:
    /// - Cj(V) = Cjo / (1 - V/Vj)^m
    /// - At V = 0: Cj = Cjo / 1^m = Cjo
    @Test("Zero bias junction capacitance equals Cjo")
    func zeroBiasCapacitance() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [
                "is": .real(isat),
                "cjo": .real(cjo),
                "vj": .real(vj),
                "m": .real(m),
                "tt": .real(0)  // No diffusion capacitance for this test
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = DiodeComplexStampCollector()

        // Zero bias state (V_anode = V_cathode = 0)
        let state = SolutionState(
            variables: [0.0, 0.0],  // Vd = 0
            variableMap: variableMap
        )

        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )

        let omega = 2 * Double.pi * 1e6  // 1 MHz
        bound.stampAC(into: &stamper, state: state, omega: omega)

        // Susceptance B = ωC should appear on diagonal
        // At zero bias, Cj = Cjo
        let expectedB = omega * cjo
        let actualB = collector.imaginarySum(row: 0, col: 0)

        #expect(abs(actualB - expectedB) / expectedB < 0.02,
                "Susceptance at V=0 should be ω×Cjo = \(expectedB), got \(actualB)")
    }

    // MARK: - Test 2: Reverse Bias Junction Capacitance

    /// Verifies depletion capacitance in reverse bias.
    ///
    /// Mathematical basis:
    /// - Cj(V) = Cjo / (1 - V/Vj)^m
    /// - For Vd = -2V, Vj = 0.7V, m = 0.5:
    ///   Cj = Cjo / (1 + 2/0.7)^0.5 = Cjo / 2.04 ≈ 0.49 × Cjo
    @Test("Reverse bias junction capacitance follows 1/(1-V/Vj)^m")
    func reverseBiasCapacitance() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [
                "is": .real(isat),
                "cjo": .real(cjo),
                "vj": .real(vj),
                "m": .real(m),
                "tt": .real(0)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = DiodeComplexStampCollector()

        // Reverse bias: Vd = -2V
        let vd = -2.0
        let state = SolutionState(
            variables: [vd, 0.0],  // Anode at -2V, cathode at 0
            variableMap: variableMap
        )

        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )

        let omega = 2 * Double.pi * 1e6
        bound.stampAC(into: &stamper, state: state, omega: omega)

        // Expected: Cj = Cjo / (1 - Vd/Vj)^m = 10pF / (1 + 2/0.7)^0.5
        let expectedCj = cjo / pow(1.0 - vd / vj, m)
        let expectedB = omega * expectedCj
        let actualB = collector.imaginarySum(row: 0, col: 0)

        #expect(abs(actualB - expectedB) / expectedB < 0.05,
                "Reverse bias capacitance: expected \(expectedCj * 1e12) pF, got susceptance \(actualB)")
    }

    // MARK: - Test 3: Forward Bias Linear Extrapolation

    /// Verifies linear extrapolation in forward bias to avoid singularity.
    ///
    /// Mathematical basis:
    /// - Standard formula has singularity at V = Vj
    /// - For V > 0.5×Vj, use linear extrapolation:
    ///   C = C(0.5×Vj) + dC/dV|_{0.5Vj} × (V - 0.5×Vj)
    @Test("Forward bias uses linear extrapolation to avoid singularity")
    func forwardBiasLinearExtrapolation() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [
                "is": .real(isat),
                "cjo": .real(cjo),
                "vj": .real(vj),
                "m": .real(m),
                "tt": .real(0)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let omega = 2 * Double.pi * 1e6

        // Test at V = 0.6V (> 0.5 × Vj = 0.35V)
        let vd = 0.6
        let collector = DiodeComplexStampCollector()
        let state = SolutionState(
            variables: [vd, 0.0],
            variableMap: variableMap
        )
        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )
        bound.stampAC(into: &stamper, state: state, omega: omega)

        let actualB = collector.imaginarySum(row: 0, col: 0)
        let actualC = actualB / omega

        // The capacitance should be finite and larger than Cjo (forward extrapolation)
        #expect(actualC.isFinite, "Capacitance must be finite in forward bias")
        #expect(actualC > cjo, "Forward bias capacitance should exceed Cjo: got \(actualC * 1e12) pF")

        // Capacitance should not blow up (linear extrapolation keeps it bounded)
        #expect(actualC < 10 * cjo, "Forward bias capacitance should be bounded: got \(actualC * 1e12) pF")
    }

    // MARK: - Test 4: Diffusion Capacitance

    /// Verifies diffusion capacitance: Cd = τ × gd.
    ///
    /// Physical basis:
    /// - In forward bias, minority carrier charge storage adds diffusion capacitance
    /// - Cd = τ × Is/Vt × exp(Vd/Vt) = τ × gd (where gd is small-signal conductance)
    @Test("Diffusion capacitance Cd = τ × gd in forward bias")
    func diffusionCapacitance() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [
                "is": .real(isat),
                "cjo": .real(0),  // No junction capacitance
                "tt": .real(transitTime)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let omega = 2 * Double.pi * 1e6

        // Forward bias: Vd = 0.7V (strong forward)
        let vd = 0.7
        let vt = 0.02585  // Thermal voltage at 300K

        let collector = DiodeComplexStampCollector()
        let state = SolutionState(
            variables: [vd, 0.0],
            variableMap: variableMap
        )
        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )
        bound.stampAC(into: &stamper, state: state, omega: omega)

        // Expected gd = Is/Vt × exp(Vd/Vt)
        let expArg = min(vd / vt, 40.0)  // Limit to prevent overflow
        let gd = (isat / vt) * exp(expArg)

        // Expected diffusion capacitance: Cd = τ × gd
        let expectedCd = transitTime * gd
        let expectedB = omega * expectedCd

        let actualB = collector.imaginarySum(row: 0, col: 0)

        // Allow significant tolerance due to gmin and numerical effects
        #expect(abs(actualB - expectedB) / expectedB < 0.2,
                "Diffusion capacitance B = ω×τ×gd: expected \(expectedB), got \(actualB)")
    }

    // MARK: - Test 5: Total AC Capacitance (Depletion + Diffusion)

    /// Verifies total AC capacitance is sum of junction and diffusion components.
    @Test("Total AC capacitance = Cj(depletion) + Cd(diffusion)")
    func totalACCapacitance() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [
                "is": .real(isat),
                "cjo": .real(cjo),
                "vj": .real(vj),
                "m": .real(m),
                "tt": .real(transitTime)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let omega = 2 * Double.pi * 1e6

        // Test at mild forward bias: Vd = 0.3V (< 0.5×Vj for depletion model)
        let vd = 0.3
        let vt = 0.02585

        let collector = DiodeComplexStampCollector()
        let state = SolutionState(
            variables: [vd, 0.0],
            variableMap: variableMap
        )
        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )
        bound.stampAC(into: &stamper, state: state, omega: omega)

        // Expected depletion capacitance
        let expectedCj = cjo / pow(1.0 - vd / vj, m)

        // Expected diffusion capacitance
        let expArg = min(vd / vt, 40.0)
        let gd = (isat / vt) * exp(expArg)
        let expectedCd = transitTime * gd

        // Total capacitance
        let expectedCtotal = expectedCj + expectedCd
        let expectedB = omega * expectedCtotal

        let actualB = collector.imaginarySum(row: 0, col: 0)

        // The depletion component should dominate at this bias
        #expect(abs(actualB - expectedB) / expectedB < 0.1,
                "Total capacitance: expected \(expectedCtotal * 1e12) pF, got \(actualB / omega * 1e12) pF")
    }

    // MARK: - Test 6: Capacitance Frequency Independence

    /// Verifies that capacitance value is independent of frequency.
    ///
    /// The susceptance B = ωC should scale linearly with ω,
    /// meaning C = B/ω should be constant.
    @Test("Junction capacitance is frequency independent")
    func capacitanceFrequencyIndependence() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [
                "is": .real(isat),
                "cjo": .real(cjo),
                "vj": .real(vj),
                "m": .real(m),
                "tt": .real(0)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let state = SolutionState(
            variables: [-1.0, 0.0],  // Vd = -1V reverse bias
            variableMap: variableMap
        )

        // Test at two different frequencies
        let freq1 = 1e6
        let freq2 = 100e6
        let omega1 = 2 * Double.pi * freq1
        let omega2 = 2 * Double.pi * freq2

        // First frequency
        let collector1 = DiodeComplexStampCollector()
        var stamper1 = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector1.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )
        bound.stampAC(into: &stamper1, state: state, omega: omega1)
        let B1 = collector1.imaginarySum(row: 0, col: 0)
        let C1 = B1 / omega1

        // Second frequency
        let collector2 = DiodeComplexStampCollector()
        var stamper2 = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, re, im in collector2.addMatrix(r, c, re, im) },
            stampRHS: { _, _, _ in }
        )
        bound.stampAC(into: &stamper2, state: state, omega: omega2)
        let B2 = collector2.imaginarySum(row: 0, col: 0)
        let C2 = B2 / omega2

        // Capacitance should be the same at both frequencies
        #expect(abs(C1 - C2) / C1 < 1e-10,
                "Capacitance should be frequency independent: C(\(freq1/1e6)MHz)=\(C1*1e12)pF, C(\(freq2/1e6)MHz)=\(C2*1e12)pF")
    }
}
