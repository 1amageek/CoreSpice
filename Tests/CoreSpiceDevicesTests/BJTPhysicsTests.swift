import Testing
import Synchronization
import Foundation
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

/// Thread-safe collector for matrix stamp entries used in BJT physics tests.
private final class BJTPhysicsStampCollector: Sendable {
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

/// Unit tests for BJT Ebers-Moll model physics.
///
/// These tests verify the correct implementation of BJT operating regions:
/// 1. Cutoff region: Both junctions reverse biased (Ic ≈ 0)
/// 2. Forward active: BE forward, BC reverse (Ic = βf × Ib)
/// 3. Saturation: Both junctions forward biased
/// 4. Small-signal parameters: gm, go, gpi verification
///
/// Stamping pattern in BoundBJT (SPICE3F5 form):
/// - gm stamps at: (C,B)+gm, (C,E)-gm, (E,B)-gm, (E,E)+gm
/// - go stamps at: (C,C)+go, (E,E)+go, (C,E)-go, (E,C)-go
/// - gpi stamps at: (B,B)+gpi, (E,E)+gpi, (B,E)-gpi, (E,B)-gpi
/// - gmu stamps at: (B,B)+gmu, (C,C)+gmu, (B,C)-gmu, (C,B)-gmu
///
/// Note: At (C,B) position, total = gm - gmu (they partially cancel!)
@Suite("BJT Physics Tests")
struct BJTPhysicsTests {

    /// gmin used in BoundBJT for numerical stability.
    private let gmin: Double = 1e-12

    /// Thermal voltage at room temperature (≈ 300K).
    private let vt: Double = 0.02585

    // MARK: - Test 1: Cutoff Region

    /// Verifies cutoff region behavior when both junctions are reverse biased.
    ///
    /// Physical basis:
    /// - Cutoff: Vbe < 0 AND Vbc < 0
    /// - Collector current Ic ≈ 0 (only leakage)
    /// - Small-signal parameters are at gmin level
    ///
    /// Verification strategy:
    /// - Check (B,E) position which has only -gpi stamp
    /// - Check RHS currents are negligible
    @Test("NPN cutoff region: both junctions reverse biased")
    func npnCutoffRegion() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)

        let isat = 1e-15
        let bf: Double = 100

        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(isat), "bf": .real(bf)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector_ = BJTPhysicsStampCollector()

        // Cutoff: Vc = 5V, Vb = 0V, Ve = 0.5V
        // Vbe = 0 - 0.5 = -0.5V (reverse biased)
        // Vbc = 0 - 5 = -5V (reverse biased)
        let state = SolutionState(variables: [5.0, 0.0, 0.5], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // In cutoff, gpi ≈ gmin (both junctions reverse biased)
        // Check (B,E) position which has only -gpi
        let baseEmitterStamp = collector_.matrixSum(row: 1, col: 2)
        #expect(baseEmitterStamp < 0, "gpi stamp at (B,E) should be negative")
        #expect(abs(baseEmitterStamp) < 1e-6, "gpi in cutoff should be very small (near gmin)")

        // Check (B,C) position which has only -gmu
        let baseCollectorStamp = collector_.matrixSum(row: 1, col: 0)
        #expect(baseCollectorStamp < 0, "gmu stamp at (B,C) should be negative")
        #expect(abs(baseCollectorStamp) < 1e-6, "gmu in cutoff should be very small (near gmin)")

        // RHS should be small (essentially zero current in cutoff)
        let collectorRHS = abs(collector_.rhsSum(row: 0))
        let baseRHS = abs(collector_.rhsSum(row: 1))

        #expect(collectorRHS < 1e-9, "Collector current in cutoff should be negligible")
        #expect(baseRHS < 1e-9, "Base current in cutoff should be negligible")
    }

    // MARK: - Test 2: Forward Active Region

    /// Verifies forward active region behavior.
    ///
    /// Physical basis:
    /// - Forward active: Vbe > 0 (forward biased) AND Vbc < 0 (reverse biased)
    /// - Ic = βf × Ib (current gain relationship)
    /// - gm/gpi ≈ βf (small-signal equivalent)
    ///
    /// Verification strategy:
    /// - Check (B,E) position for gpi (only -gpi there)
    /// - Calculate gm from (E,B) which has -gm -gpi, so gm = -stamp(E,B) - gpi
    /// - Verify gm/gpi ≈ bf
    @Test("NPN forward active region: gm/gpi ≈ βf")
    func npnForwardActiveRegion() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)

        let isat = 1e-15
        let bf: Double = 100

        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(isat), "bf": .real(bf)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector_ = BJTPhysicsStampCollector()

        // Forward active: Vc = 5V, Vb = 0.7V, Ve = 0V
        // Vbe = 0.7 - 0 = 0.7V (forward biased)
        // Vbc = 0.7 - 5 = -4.3V (reverse biased)
        let vbe = 0.7
        let state = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Calculate expected gm and gpi from Ebers-Moll:
        // gm = Is/(nf*Vt) * exp(Vbe/(nf*Vt))
        // gpi = Is/(bf*nf*Vt) * exp(Vbe/(nf*Vt))
        // Therefore: gm/gpi = bf

        let expBE = exp(vbe / vt)
        let expectedGm = (isat / vt) * expBE
        let expectedGpi = (isat / (bf * vt)) * expBE

        // Extract gpi from (B,E) position: only -gpi there
        let gpi = -collector_.matrixSum(row: 1, col: 2)
        #expect(gpi > 0, "gpi should be positive")

        // Verify gpi matches formula (allowing for gmin addition)
        #expect(abs(gpi - expectedGpi) / expectedGpi < 0.05,
                "gpi should match formula: expected \(expectedGpi), got \(gpi)")

        // Extract gm from (E,B): has -gm -gpi
        // So gm = -stamp(E,B) - gpi
        let emitterBaseStamp = collector_.matrixSum(row: 2, col: 1)
        let gm = -emitterBaseStamp - gpi
        #expect(gm > 0, "gm should be positive")

        // Verify gm matches formula
        #expect(abs(gm - expectedGm) / expectedGm < 0.05,
                "gm should match formula: expected \(expectedGm), got \(gm)")

        // Verify current gain relationship: gm/gpi ≈ bf
        let gmGpiRatio = gm / gpi
        #expect(abs(gmGpiRatio - bf) / bf < 0.02,
                "gm/gpi should equal bf=\(bf), got \(gmGpiRatio)")
    }

    // MARK: - Test 3: Saturation Region

    /// Verifies saturation region behavior when both junctions are forward biased.
    ///
    /// Physical basis:
    /// - Saturation: Vbe > 0 (forward) AND Vbc > 0 (forward)
    /// - Both junctions conduct → gmu becomes significant
    /// - Vce_sat is typically 0.1-0.2V
    @Test("NPN saturation region: both junctions forward biased")
    func npnSaturationRegion() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)

        let isat = 1e-15
        let bf: Double = 100
        let br: Double = 1  // Reverse beta

        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(isat), "bf": .real(bf), "br": .real(br)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        // --- Saturation condition ---
        let collectorSat = BJTPhysicsStampCollector()

        // Saturation: Vc = 0.2V, Vb = 0.7V, Ve = 0V
        // Vbe = 0.7V (forward biased)
        // Vbc = 0.7 - 0.2 = 0.5V (forward biased!)
        let vbc = 0.5
        let stateSat = SolutionState(variables: [0.2, 0.7, 0.0], variableMap: variableMap)
        var stamperSat = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorSat.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorSat.addRHS(r, v) }
        )

        bound.stampDC(into: &stamperSat, state: stateSat)

        // gmu = Is/(br*nr*Vt) * exp(Vbc/(nr*Vt))
        let expBC = exp(vbc / vt)
        let expectedGmu = (isat / (br * vt)) * expBC

        // Extract gmu from (B,C) position: only -gmu there
        let gmu = -collectorSat.matrixSum(row: 1, col: 0)
        #expect(gmu > 1e-6, "gmu should be significant in saturation")

        // Verify gmu matches formula (with tolerance for gmin)
        let gmuError = abs(gmu - expectedGmu) / expectedGmu
        #expect(gmuError < 0.05,
                "gmu should match formula: expected \(expectedGmu), got \(gmu)")

        // --- Compare with forward active (gmu should be much smaller) ---
        let collectorFA = BJTPhysicsStampCollector()

        // Forward active: Vc = 5V, Vb = 0.7V, Ve = 0V
        // Vbc = 0.7 - 5 = -4.3V (reverse biased)
        let stateFA = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        var stamperFA = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorFA.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorFA.addRHS(r, v) }
        )

        bound.stampDC(into: &stamperFA, state: stateFA)

        let gmuFA = -collectorFA.matrixSum(row: 1, col: 0)
        let gmuSat = gmu

        // In saturation, gmu should be orders of magnitude larger than in forward active
        #expect(gmuSat / gmuFA > 1e5,
                "gmu in saturation (\(gmuSat)) should be much larger than in forward active (\(gmuFA))")
    }

    // MARK: - Test 4: Small-Signal Parameters with Early Effect

    /// Verifies that Early effect modulates gm and creates go.
    ///
    /// Mathematical basis:
    /// - gm = Is/(nf*Vt) * exp(Vbe/(nf*Vt)) * (1 + Vce/Vaf)
    /// - go = |Ic| / Vaf (output conductance from Early effect)
    /// - gpi = Is/(bf*nf*Vt) * exp(Vbe/(nf*Vt)) (no Early factor)
    @Test("Early effect modulates gm")
    func earlyEffectModulatesGm() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)

        let isat = 1e-15
        let bf: Double = 100
        let vaf: Double = 100  // Forward Early voltage

        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(isat), "bf": .real(bf), "vaf": .real(vaf)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        // --- High Vce case ---
        let collectorHighVce = BJTPhysicsStampCollector()
        let vce_high = 10.0
        let stateHighVce = SolutionState(variables: [10.0, 0.7, 0.0], variableMap: variableMap)
        var stamperHighVce = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorHighVce.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorHighVce.addRHS(r, v) }
        )

        bound.stampDC(into: &stamperHighVce, state: stateHighVce)

        // --- Low Vce case ---
        let collectorLowVce = BJTPhysicsStampCollector()
        let vce_low = 1.0
        let stateLowVce = SolutionState(variables: [1.0, 0.7, 0.0], variableMap: variableMap)
        var stamperLowVce = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorLowVce.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorLowVce.addRHS(r, v) }
        )

        bound.stampDC(into: &stamperLowVce, state: stateLowVce)

        // Extract gpi from (B,E) position (same for both - no Early effect on gpi)
        let gpi_high = -collectorHighVce.matrixSum(row: 1, col: 2)
        let gpi_low = -collectorLowVce.matrixSum(row: 1, col: 2)

        // gpi should be the same regardless of Vce (no Early factor)
        #expect(abs(gpi_high - gpi_low) / gpi_low < 0.01,
                "gpi should not depend on Vce: high=\(gpi_high), low=\(gpi_low)")

        // Extract gm from (E,B): -gm - gpi, so gm = -stamp - gpi
        let gm_high = -collectorHighVce.matrixSum(row: 2, col: 1) - gpi_high
        let gm_low = -collectorLowVce.matrixSum(row: 2, col: 1) - gpi_low

        // gm at Vce=10V should be (1 + 10/100) / (1 + 1/100) = 1.1/1.01 ≈ 1.089x larger
        let expectedGmRatio = (1.0 + vce_high / vaf) / (1.0 + vce_low / vaf)
        let actualGmRatio = gm_high / gm_low

        #expect(abs(actualGmRatio - expectedGmRatio) / expectedGmRatio < 0.02,
                "gm ratio should reflect Early effect: expected \(expectedGmRatio), got \(actualGmRatio)")

        // Verify go is present: check (C,E) position
        // (C,E) has -gm - go, and (E,C) also has -go
        // So go contributes to both (C,E) and (E,C) as -go
        let ce_high = collectorHighVce.matrixSum(row: 0, col: 2)  // -gm - go
        let ec_high = collectorHighVce.matrixSum(row: 2, col: 0)  // -go

        // ec_high should be -go
        let go_high = -ec_high
        #expect(go_high > 0, "go should be positive with Early effect")

        // go = |Ic| / Vaf, should be significant at high Vce
        // Ic ≈ gm * Vbe / (earlyFactor) approximately
        #expect(go_high > 1e-6, "go should be significant with Early voltage")
    }

    // MARK: - Test 5: PNP Polarity Verification

    /// Verifies that PNP transistor has correct polarity handling.
    ///
    /// Physical basis:
    /// - PNP: Current flows from emitter to collector
    /// - Veb (not Vbe) is the forward bias voltage
    /// - Matrix stamps are identical (polarity cancels in Jacobian)
    /// - RHS current sources have opposite signs
    @Test("PNP forward active region polarity")
    func pnpForwardActivePolarit() throws {
        let descPNP = PNPDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)

        let isat = 1e-15
        let bf: Double = 100

        let instancePNP = Instance(
            name: "Q1",
            typeName: "pnp",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(isat), "bf": .real(bf)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var contextPNP = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let boundPNP = try descPNP.bind(instance: instancePNP, context: &contextPNP)

        let collectorPNP = BJTPhysicsStampCollector()

        // PNP forward active: Vc = 0V, Vb = 4.3V, Ve = 5V
        // Veb = Ve - Vb = 5 - 4.3 = 0.7V (forward biased for PNP)
        // Vcb = Vc - Vb = 0 - 4.3 = -4.3V (reverse biased)
        let statePNP = SolutionState(variables: [0.0, 4.3, 5.0], variableMap: variableMap)
        var stamperPNP = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorPNP.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorPNP.addRHS(r, v) }
        )

        boundPNP.stampDC(into: &stamperPNP, state: statePNP)

        // --- Compare with NPN at equivalent bias ---
        let descNPN = NPNDescriptor()
        let instanceNPN = Instance(
            name: "Q2",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(isat), "bf": .real(bf)]
        )

        var contextNPN = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let boundNPN = try descNPN.bind(instance: instanceNPN, context: &contextNPN)

        let collectorNPN = BJTPhysicsStampCollector()

        // NPN forward active: Vc = 5V, Vb = 0.7V, Ve = 0V
        // Vbe = 0.7V (same forward bias)
        let stateNPN = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        var stamperNPN = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collectorNPN.addMatrix(r, c, v) },
            stampRHS: { r, v in collectorNPN.addRHS(r, v) }
        )

        boundNPN.stampDC(into: &stamperNPN, state: stateNPN)

        // Extract gpi from (B,E) for both
        let gpiPNP = -collectorPNP.matrixSum(row: 1, col: 2)
        let gpiNPN = -collectorNPN.matrixSum(row: 1, col: 2)

        // Matrix stamps should be identical for NPN and PNP
        // (polarity flip in both currents and voltages cancel)
        #expect(abs(gpiPNP - gpiNPN) / gpiNPN < 0.01,
                "PNP and NPN gpi should be equal for equivalent bias: NPN=\(gpiNPN), PNP=\(gpiPNP)")

        // RHS signs differ for PNP vs NPN
        let collectorRHS_PNP = collectorPNP.rhsSum(row: 0)
        let collectorRHS_NPN = collectorNPN.rhsSum(row: 0)

        // The RHS current sources have opposite signs
        #expect(collectorRHS_PNP * collectorRHS_NPN < 0,
                "PNP and NPN RHS should have opposite signs: PNP=\(collectorRHS_PNP), NPN=\(collectorRHS_NPN)")
    }
}
