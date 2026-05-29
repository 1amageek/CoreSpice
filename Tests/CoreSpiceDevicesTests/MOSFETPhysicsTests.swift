import Testing
import Synchronization
import Foundation
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

/// Thread-safe collector for matrix stamp entries used in tests.
private final class MOSStampCollector: Sendable {
    private let _matrix = Mutex<[(Int, Int, Double)]>([])
    private let _rhs = Mutex<[(Int, Double)]>([])

    func addMatrix(_ r: Int, _ c: Int, _ v: Double) {
        _matrix.withLock { $0.append((r, c, v)) }
    }
    func addRHS(_ r: Int, _ v: Double) {
        _rhs.withLock { $0.append((r, v)) }
    }
    var matrixEntries: [(Int, Int, Double)] { _matrix.withLock { $0 } }
    var rhsEntries: [(Int, Double)] { _rhs.withLock { $0 } }

    func matrixSum(row: Int, col: Int) -> Double {
        matrixEntries.filter { $0.0 == row && $0.1 == col }.map { $0.2 }.reduce(0, +)
    }
    func rhsSum(row: Int) -> Double {
        rhsEntries.filter { $0.0 == row }.map { $0.1 }.reduce(0, +)
    }
    func reset() {
        _matrix.withLock { $0.removeAll() }
        _rhs.withLock { $0.removeAll() }
    }
}

/// Tests for MOSFET Level 1 (Shichman-Hodges) model physics.
///
/// Verifies:
/// 1. Operating region transitions (cutoff, linear, saturation)
/// 2. Body effect threshold modulation
/// 3. Small-signal parameter calculations (gm, gds, gmbs)
@Suite("MOSFET Level 1 Physics Tests")
struct MOSFETPhysicsTests {

    // MARK: - Test 1: Cutoff-to-Linear Transition

    /// Verify MOSFET current is near-zero in cutoff, flows in linear region.
    ///
    /// Physics: In cutoff (Vgs < Vth), Ids is negligible.
    /// The smoothClamp function provides continuous transition:
    /// `smoothClamp(x) = 0.5 * (x + sqrt(x² + δ²))` where δ = 0.025V
    ///
    /// Test conditions:
    /// - Vth = 0.7V, Vds = 0.1V
    /// - Cutoff: Vgs = 0V -> Ids ≈ 0
    /// - Linear: Vgs = 1.5V -> Ids > 0
    @Test("NMOS cutoff-to-linear transition")
    func nmosCutoffToLinearTransition() throws {
        let desc = NMOSL1Descriptor()
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let bulk = Node(id: 4)

        // Parameters: Vth=0.7V, Kp=110uA/V^2, W/L=10
        // beta = Kp * W/L = 110e-6 * 10 = 1.1e-3 A/V^2
        let instance = Instance(
            name: "M1",
            typeName: "nmos_l1",
            nodes: [drain, gate, source, bulk],
            parameters: [
                "vto": .real(0.7),
                "kp": .real(110e-6),
                "w": .real(10e-6),
                "l": .real(1e-6),
                "lambda": .real(0.0)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2,
            .nodeVoltage(bulk): 3
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 4)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = MOSStampCollector()
        let beta = 110e-6 * 10.0  // 1.1e-3 A/V^2
        let vds = 0.1

        // --- Cutoff: Vgs = 0V ---
        let vgsCutoff = 0.0
        let stateCutoff = SolutionState(
            variables: [vds, vgsCutoff, 0.0, 0.0],  // Vd=0.1, Vg=0, Vs=0, Vb=0
            variableMap: variableMap
        )
        var stamperCutoff = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )
        bound.stampDC(into: &stamperCutoff, state: stateCutoff)

        // In cutoff, gds should be near gmin (1e-12)
        let gdsCutoff = collector.matrixSum(row: 0, col: 0)
        #expect(gdsCutoff > 0, "gds must be positive (at least gmin)")
        #expect(gdsCutoff < 1e-6, "gds in cutoff should be small, got \(gdsCutoff)")

        // --- Linear: Vgs = 1.5V ---
        collector.reset()
        let vgsLinear = 1.5
        let stateLinear = SolutionState(
            variables: [vds, vgsLinear, 0.0, 0.0],
            variableMap: variableMap
        )
        var stamperLinear = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )
        bound.stampDC(into: &stamperLinear, state: stateLinear)

        // In linear: vgst = 1.5 - 0.7 = 0.8V
        // gds = beta * (vgst - vds) = 1.1e-3 * 0.7 = 7.7e-4 S
        let gdsLinear = collector.matrixSum(row: 0, col: 0)
        let expectedGds = beta * (0.8 - 0.1)

        // gds should be significantly larger in linear than cutoff
        #expect(gdsLinear > gdsCutoff * 1000,
                "gds in linear should be >> cutoff: \(gdsLinear) vs \(gdsCutoff)")

        // gds should be close to expected (allow 20% for smoothing effects)
        #expect(abs(gdsLinear - expectedGds) / expectedGds < 0.2,
                "gds in linear should be ~\(expectedGds), got \(gdsLinear)")

        // gm contribution to (drain, gate) stamp
        let gmContrib = collector.matrixSum(row: 0, col: 1)
        let expectedGm = beta * vds  // 1.1e-4 S
        #expect(abs(gmContrib - expectedGm) / expectedGm < 0.2,
                "gm in linear should be ~\(expectedGm), got \(gmContrib)")
    }

    // MARK: - Test 2: Linear-to-Saturation Transition

    /// Verify current saturation at Vds = Vgs - Vth.
    ///
    /// Physics: At Vds = Vgst, the MOSFET transitions from linear to saturation.
    /// - Linear (Vds < Vgst): Ids = beta * (Vgst * Vds - 0.5 * Vds^2)
    /// - Saturation (Vds >= Vgst): Ids = 0.5 * beta * Vgst^2
    ///
    /// Test: Vgs = 2V, Vth = 0.7V -> Vgst = 1.3V
    /// In saturation (Vds > Vgst), gds should be near gmin (without CLM)
    @Test("NMOS linear-to-saturation transition at Vds = Vgst")
    func nmosLinearToSaturationTransition() throws {
        let desc = NMOSL1Descriptor()
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let bulk = Node(id: 4)

        let instance = Instance(
            name: "M1",
            typeName: "nmos_l1",
            nodes: [drain, gate, source, bulk],
            parameters: [
                "vto": .real(0.7),
                "kp": .real(110e-6),
                "w": .real(10e-6),
                "l": .real(1e-6),
                "lambda": .real(0.0)  // No CLM for clean comparison
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2,
            .nodeVoltage(bulk): 3
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 4)
        let bound = try desc.bind(instance: instance, context: &context)

        let beta = 110e-6 * 10.0  // 1.1e-3 A/V^2
        let vth = 0.7
        let vgs = 2.0
        let vgst = vgs - vth  // 1.3V

        // --- Deep saturation: Vds = 3V (> Vgst = 1.3V) ---
        let vdsSat = 3.0
        let collector = MOSStampCollector()
        let stateSat = SolutionState(
            variables: [vdsSat, vgs, 0.0, 0.0],
            variableMap: variableMap
        )
        var stamperSat = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )
        bound.stampDC(into: &stamperSat, state: stateSat)

        // In saturation without CLM, gds should be near gmin (1e-12)
        let gdsSat = collector.matrixSum(row: 0, col: 0)
        #expect(gdsSat < 1e-9, "gds in saturation (no CLM) should be ~gmin, got \(gdsSat)")

        // gm in saturation = beta * vgst = 1.1e-3 * 1.3 = 1.43e-3 S
        let gmSat = collector.matrixSum(row: 0, col: 1)
        let expectedGmSat = beta * vgst
        #expect(abs(gmSat - expectedGmSat) / expectedGmSat < 0.15,
                "gm in saturation should be ~\(expectedGmSat), got \(gmSat)")
    }

    // MARK: - Test 3: Body Effect (Threshold Voltage Modulation)

    /// Verify body effect modulates threshold voltage.
    ///
    /// Physics: Vth = Vto + gamma * (sqrt(2*phi - Vbs) - sqrt(2*phi))
    /// With Vbs < 0 (reverse-biased body-source), Vth increases.
    ///
    /// Test: phi = 0.6V, gamma = 0.5 V^0.5, Vto = 0.7V
    /// - Vbs = 0V: Vth = 0.7V
    /// - Vbs = -2V: Vth ≈ 1.05V (increased threshold reduces gm)
    @Test("NMOS body effect threshold voltage modulation")
    func nmosBodyEffect() throws {
        let desc = NMOSL1Descriptor()
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let bulk = Node(id: 4)

        let phi = 0.6
        let gamma = 0.5
        let vto = 0.7

        let instance = Instance(
            name: "M1",
            typeName: "nmos_l1",
            nodes: [drain, gate, source, bulk],
            parameters: [
                "vto": .real(vto),
                "kp": .real(110e-6),
                "w": .real(10e-6),
                "l": .real(1e-6),
                "gamma": .real(gamma),
                "phi": .real(phi),
                "lambda": .real(0.0)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2,
            .nodeVoltage(bulk): 3
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 4)
        let bound = try desc.bind(instance: instance, context: &context)

        let beta = 110e-6 * 10.0
        let vds = 2.0  // Deep saturation
        let vgs = 1.5

        // --- Vbs = 0V: Vth = 0.7V ---
        let vthNoBody = vto
        let vgst0 = vgs - vthNoBody  // 0.8V

        let collector0 = MOSStampCollector()
        let state0 = SolutionState(
            variables: [vds, vgs, 0.0, 0.0],  // Vb = Vs = 0 -> Vbs = 0
            variableMap: variableMap
        )
        var stamper0 = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector0.addMatrix(r, c, v) },
            stampRHS: { r, v in collector0.addRHS(r, v) }
        )
        bound.stampDC(into: &stamper0, state: state0)
        let gm0 = collector0.matrixSum(row: 0, col: 1)

        // --- Vbs = -2V: Vth increases ---
        let vbs_neg = -2.0
        let twoPhi = 2.0 * phi
        let vthWithBody = vto + gamma * (sqrt(twoPhi - vbs_neg) - sqrt(twoPhi))
        let vgstWithBody = vgs - vthWithBody

        let collectorBody = MOSStampCollector()
        // Source at 0V, Bulk at -2V -> Vbs = -2V
        let stateBody = SolutionState(
            variables: [vds, vgs, 0.0, vbs_neg],  // Vb = -2V, Vs = 0 -> Vbs = -2
            variableMap: variableMap
        )
        var stamperBody = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorBody.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorBody.addRHS(r, v) }
        )
        bound.stampDC(into: &stamperBody, state: stateBody)
        let gmBody = collectorBody.matrixSum(row: 0, col: 1)

        // With body effect, vgst is smaller, so gm should decrease
        #expect(gmBody < gm0, "gm should decrease with body effect: \(gmBody) < \(gm0)")

        // Verify expected gm values (approximately)
        let expectedGm0 = beta * vgst0
        let expectedGmBody = beta * vgstWithBody

        #expect(abs(gm0 - expectedGm0) / expectedGm0 < 0.2,
                "gm without body effect: expected \(expectedGm0), got \(gm0)")
        #expect(abs(gmBody - expectedGmBody) / expectedGmBody < 0.2,
                "gm with body effect: expected \(expectedGmBody), got \(gmBody)")

        // Verify gmbs exists (bulk transconductance)
        let gmbs = collectorBody.matrixSum(row: 0, col: 3)
        #expect(gmbs != 0, "gmbs should be non-zero with gamma > 0, got \(gmbs)")
    }

    // MARK: - Test 4: Small-Signal Parameters (gm, gds, gmbs)

    /// Verify small-signal parameter calculations match analytical formulas.
    ///
    /// Physics:
    /// - Linear: gm = beta * Vds, gds = beta * (Vgst - Vds)
    /// - Saturation: gm = beta * Vgst * (1 + lambda*Vds), gds = 0.5 * beta * Vgst^2 * lambda
    /// - gmbs = gm * gamma / (2 * sqrt(2*phi - Vbs))
    @Test("NMOS small-signal parameter verification")
    func nmosSmallSignalParameters() throws {
        let desc = NMOSL1Descriptor()
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let bulk = Node(id: 4)

        let vto = 0.7
        let kp = 110e-6
        let w = 10e-6
        let l = 1e-6
        let gamma = 0.4
        let phi = 0.6
        let lambda = 0.02

        let instance = Instance(
            name: "M1",
            typeName: "nmos_l1",
            nodes: [drain, gate, source, bulk],
            parameters: [
                "vto": .real(vto),
                "kp": .real(kp),
                "w": .real(w),
                "l": .real(l),
                "gamma": .real(gamma),
                "phi": .real(phi),
                "lambda": .real(lambda)
            ]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2,
            .nodeVoltage(bulk): 3
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 4)
        let bound = try desc.bind(instance: instance, context: &context)

        let beta = kp * w / l  // 1.1e-3
        let vgs = 2.0
        let vds = 3.0  // Saturation (Vds > Vgs - Vth)
        let vbs = 0.0
        let vgst = vgs - vto  // 1.3V

        let collector = MOSStampCollector()
        let state = SolutionState(
            variables: [vds, vgs, 0.0, vbs],
            variableMap: variableMap
        )
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )
        bound.stampDC(into: &stamper, state: state)

        // Expected values in saturation with CLM:
        // gm = beta * vgst * (1 + lambda * vds)
        // gds = 0.5 * beta * vgst^2 * lambda
        // gmbs = gm * gamma / (2 * sqrt(phi - vbs))   (SPICE PHI used directly)
        let clm = 1.0 + lambda * vds
        let expectedGm = beta * vgst * clm
        let expectedGds = 0.5 * beta * vgst * vgst * lambda
        let expectedGmbs = expectedGm * gamma / (2.0 * sqrt(phi - vbs))

        let gm = collector.matrixSum(row: 0, col: 1)  // d-g stamp
        let gds = collector.matrixSum(row: 0, col: 0)  // d-d stamp
        let gmbs = collector.matrixSum(row: 0, col: 3)  // d-b stamp

        #expect(abs(gm - expectedGm) / expectedGm < 0.15,
                "gm: expected \(expectedGm), got \(gm)")
        #expect(abs(gds - expectedGds) / expectedGds < 0.15,
                "gds: expected \(expectedGds), got \(gds)")
        #expect(abs(gmbs - expectedGmbs) / expectedGmbs < 0.2,
                "gmbs: expected \(expectedGmbs), got \(gmbs)")
    }
}
