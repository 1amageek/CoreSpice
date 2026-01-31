import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Device Physics Tests")
struct DevicePhysicsTests {

    // MARK: - L1: Diode I-V Characteristic (Shockley Equation)

    @Test("L1: Diode I-V characteristic follows Shockley equation")
    func diodeIVCharacteristic() async throws {
        // Sweep V1 from 0 to 1V in 0.05V steps
        // Circuit: V1 → R(100Ω) → D(Is=1e-14, N=1) → GND
        // I = Is × (exp(Vd/(n×Vt)) - 1), Vt ≈ 0.02585V at 27°C
        let sweepValues = Array(stride(from: 0.0, through: 1.0, by: 0.05))
        let Is = 1e-14
        let n = 1.0
        let Vt = 0.02585
        let R = 100.0

        var measuredCurrents: [Double] = []
        var measuredVoltages: [Double] = []

        for vin in sweepValues {
            let (netlist, anode) = CircuitFactory.diodeCircuit(
                v: vin, r: R,
                diodeParams: ["is": .real(Is), "n": .real(n)]
            )
            let result = try await CircuitFactory.runDC(netlist)
            let vAnode = result.voltage(at: anode)
            measuredVoltages.append(vAnode)
            measuredCurrents.append((vin - vAnode) / R)
        }

        // Verify monotonically increasing current
        for i in 1..<measuredCurrents.count {
            #expect(measuredCurrents[i] >= measuredCurrents[i - 1] - 1e-12,
                    "Diode current must be monotonically increasing")
        }

        // Verify Shockley equation at several operating points
        // For each point, compute expected Id from measured Vd
        for i in 5..<measuredVoltages.count where measuredCurrents[i] > 1e-9 {
            let vd = measuredVoltages[i]
            let expectedId = Is * (exp(vd / (n * Vt)) - 1)
            let measuredId = measuredCurrents[i]

            // Allow 5% relative error for numerical solver effects
            if expectedId > 1e-9 {
                let relError = abs(measuredId - expectedId) / expectedId
                #expect(relError < 0.05,
                        "At Vd=\(vd): I_measured=\(measuredId) vs I_expected=\(expectedId), relErr=\(relError)")
            }
        }

        // Verify forward voltage is in physically reasonable range at high current
        let vfAt1V = measuredVoltages.last!
        #expect(vfAt1V > 0.5 && vfAt1V < 0.9,
                "At 1V input, forward voltage should be ~0.6-0.8V, got \(vfAt1V)")
    }

    // MARK: - L2: BJT Output Characteristics

    @Test("L2: BJT output characteristics (Ic vs Vce family)",
          .disabled("NR solver lacks damping for nonlinear BJT convergence"))
    func bjtOutputCharacteristics() async throws {
        // Sweep Vce for multiple Ib values
        // Circuit: VCC(sweep) → RC → collector, VBB → RB(large) → base, emitter → GND
        let ibValues = [10e-6, 20e-6, 30e-6]
        let vceValues = Array(stride(from: 0.5, through: 10.0, by: 0.5))
        let bf = 100.0
        let rc = 100.0 // Small RC so we can set Vce by VCC

        for ib in ibValues {
            var icValues: [Double] = []
            // Base voltage for desired Ib: Vb ≈ 0.7V + Ib × Rb
            let rb = 0.7 / ib + 1e6 // Approximate Rb
            let vbb = ib * rb + 0.7

            for vce in vceValues {
                let vcc = vce + ib * bf * rc // Approximate VCC for desired Vce
                let (netlist, col, _) = CircuitFactory.bjtCommonEmitter(
                    vcc: vcc, rc: rc, vbb: vbb, rb: rb,
                    bjtParams: ["is": .real(1e-16), "bf": .real(bf)]
                )
                let result = try await CircuitFactory.runDC(netlist, config: CircuitFactory.nonlinearConfig)
                let vCol = result.voltage(at: col)
                let ic = (vcc - vCol) / rc
                icValues.append(ic)
            }

            // In active region, Ic ≈ β × Ib
            let expectedIc = bf * ib
            for ic in icValues {
                #expect(abs(ic - expectedIc) / expectedIc < 0.2,
                        "Ic should be ~\(expectedIc) (β×Ib), got \(ic)")
            }
        }
    }

    // MARK: - L3: MOSFET Output Characteristics

    @Test("L3: MOSFET output characteristics (Ids vs Vds family)",
          .disabled("NR solver lacks damping for nonlinear NMOS convergence"))
    func mosfetOutputCharacteristics() async throws {
        // Sweep Vds for multiple Vgs values using NMOS
        let vgsValues = [1.0, 2.0, 3.0]
        let vdsValues = Array(stride(from: 0.1, through: 5.0, by: 0.5))
        let vto = 0.7
        let kp = 110e-6
        let w = 10e-6
        let l = 1e-6
        let beta = kp * (w / l)

        for vgs in vgsValues {
            var idsValues: [Double] = []

            for vds in vdsValues {
                let (netlist, drain) = CircuitFactory.nmosCommonSource(
                    vdd: vds, rd: 1.0, vgs: vgs, // Very small Rd so Vds ≈ Vdd
                    mosParams: ["vto": .real(vto), "kp": .real(kp),
                                "w": .real(w), "l": .real(l), "lambda": .real(0.0)]
                )
                let result = try await CircuitFactory.runDC(netlist, config: CircuitFactory.nonlinearConfig)
                let vDrain = result.voltage(at: drain)
                let ids = (vds - vDrain) / 1.0 // Current through Rd
                idsValues.append(ids)
            }

            // Verify saturation/linear transition at Vds = Vgs - Vth
            let vdsSat = vgs - vto
            for (idx, vds) in vdsValues.enumerated() {
                let ids = idsValues[idx]
                if vds >= vdsSat {
                    // Saturation: Ids ≈ 0.5 × β × (Vgs - Vth)²
                    let expectedIds = 0.5 * beta * pow(vgs - vto, 2)
                    #expect(abs(ids - expectedIds) / expectedIds < 0.15,
                            "Saturation at Vgs=\(vgs), Vds=\(vds): expected \(expectedIds), got \(ids)")
                }
            }
        }
    }

    // MARK: - L4: MOSFET Transfer Characteristic (PMOS)

    @Test("L4: PMOS transfer characteristic (Ids vs Vsg)")
    func pmosTransferCharacteristic() async throws {
        // Sweep Vsg (by varying gate voltage) with fixed Vsd
        // PMOS: Vdd=5V, drain through Rd to GND, gate voltage varies
        // Vsg = Vdd - Vgate, |Vtp| = 0.7V
        let vdd = 5.0
        let rd = 1000.0
        let vtp = -0.7 // PMOS threshold (negative)
        let kp = 50e-6
        let w = 20e-6
        let l = 1e-6
        let beta = kp * (w / l)

        // Gate voltages from 5V (off) to 0V (strongly on)
        let vgateValues = Array(stride(from: 5.0, through: 0.0, by: -0.5))
        var idsValues: [Double] = []
        var drainVoltages: [Double] = []

        for vgate in vgateValues {
            let (netlist, drain) = CircuitFactory.pmosCommonSource(
                vdd: vdd, rd: rd, vgate: vgate,
                mosParams: ["vto": .real(vtp), "kp": .real(kp),
                            "w": .real(w), "l": .real(l), "lambda": .real(0.0)]
            )
            let result = try await CircuitFactory.runDC(netlist)
            let vDrain = result.voltage(at: drain)
            drainVoltages.append(vDrain)
            // PMOS current flows from source(Vdd) through device to drain
            // Drain is connected to GND through Rd → Vdrain = Ids × Rd
            idsValues.append(vDrain / rd)
        }

        // Cutoff: Vsg < |Vtp| → Ids ≈ 0
        // Vsg = Vdd - Vgate, |Vtp| = 0.7
        // Cutoff when Vgate > Vdd - |Vtp| = 4.3V
        for (idx, vgate) in vgateValues.enumerated() {
            let vsg = vdd - vgate
            if vsg < abs(vtp) - 0.1 {
                #expect(abs(idsValues[idx]) < 1e-6,
                        "Cutoff at Vgate=\(vgate) (Vsg=\(vsg)): Ids should be ~0, got \(idsValues[idx])")
            }
        }

        // Saturation: Vsg > |Vtp|, Vsd > Vsg - |Vtp|
        // Ids = 0.5 × β × (Vsg - |Vtp|)²
        for (idx, vgate) in vgateValues.enumerated() {
            let vsg = vdd - vgate
            if vsg > abs(vtp) + 0.5 {
                let expectedIds = 0.5 * beta * pow(vsg - abs(vtp), 2)
                let measuredIds = idsValues[idx]
                // Check if in saturation (Vsd > Vsg - |Vtp|)
                let vsd = vdd - drainVoltages[idx]
                if vsd > vsg - abs(vtp) && expectedIds > 1e-6 {
                    let relError = abs(measuredIds - expectedIds) / expectedIds
                    #expect(relError < 0.15,
                            "Saturation at Vsg=\(vsg): expected Ids=\(expectedIds), got \(measuredIds), relErr=\(relError)")
                }
            }
        }

        // Ids should be monotonically increasing with Vsg (decreasing Vgate)
        for i in 1..<idsValues.count {
            #expect(idsValues[i] >= idsValues[i - 1] - 1e-9,
                    "PMOS current should increase with Vsg")
        }
    }

    // MARK: - L5: BJT Early Effect

    @Test("L5: BJT Early effect (Vaf parameter)",
          .disabled("NR solver lacks damping for nonlinear BJT convergence"))
    func bjtEarlyEffect() async throws {
        // Fixed Ib, sweep Vce → Ic should increase linearly with slope Ic0/Vaf
        let vaf = 100.0
        let bf = 100.0
        let ib = 10e-6
        let rb = (1.5 - 0.7) / ib // Rb for Ib ≈ 10µA

        var icValues: [Double] = []
        let vceValues = Array(stride(from: 1.0, through: 10.0, by: 1.0))

        for vce in vceValues {
            let vcc = vce + bf * ib * 2000 // Approximate VCC
            let (netlist, col, _) = CircuitFactory.bjtCommonEmitter(
                vcc: vcc, rc: 2000, vbb: 1.5, rb: rb,
                bjtParams: ["is": .real(1e-16), "bf": .real(bf), "vaf": .real(vaf)]
            )
            let result = try await CircuitFactory.runDC(netlist, config: CircuitFactory.nonlinearConfig)
            let vCol = result.voltage(at: col)
            icValues.append((vcc - vCol) / 2000)
        }

        // Ic should increase linearly: Ic = Ic0 × (1 + Vce/Vaf)
        // Output resistance ro = Vaf/Ic0
        let ic0 = icValues[0]
        for (idx, vce) in vceValues.enumerated() {
            let expectedIc = ic0 * (1 + (vce - vceValues[0]) / vaf)
            let relError = abs(icValues[idx] - expectedIc) / ic0
            #expect(relError < 0.1,
                    "Early effect at Vce=\(vce): expected \(expectedIc), got \(icValues[idx])")
        }
    }

    // MARK: - L6: MOSFET Channel-Length Modulation (PMOS)

    @Test("L6: PMOS channel-length modulation (lambda effect)")
    func pmosChannelLengthModulation() async throws {
        // PMOS with lambda=0.04, sweep Vsd in saturation
        // Ids = 0.5 × β × (Vsg - |Vtp|)² × (1 + λ × Vsd)
        let vdd = 5.0
        let vtp = -0.7
        let kp = 50e-6
        let w = 20e-6
        let l = 1e-6
        let lambda = 0.04
        let beta = kp * (w / l)

        // Fix Vsg = 3V (gate at 2V, source at 5V) → strong saturation
        let vgate = 2.0
        let vsg = vdd - vgate // = 3V

        // Sweep Vsd by varying drain voltage via different Rd
        // Vdrain = Ids × Rd → Vsd = Vdd - Vdrain
        // Use multiple Rd values to get different operating points
        let rdValues = [500.0, 1000.0, 2000.0, 3000.0, 5000.0]
        var idsValues: [Double] = []
        var vsdValues: [Double] = []

        for rd in rdValues {
            let (netlist, drain) = CircuitFactory.pmosCommonSource(
                vdd: vdd, rd: rd, vgate: vgate,
                mosParams: ["vto": .real(vtp), "kp": .real(kp),
                            "w": .real(w), "l": .real(l), "lambda": .real(lambda)]
            )
            let result = try await CircuitFactory.runDC(netlist)
            let vDrain = result.voltage(at: drain)
            let ids = vDrain / rd
            let vsd = vdd - vDrain
            idsValues.append(ids)
            vsdValues.append(vsd)
        }

        // In saturation with CLM: Ids = 0.5 × β × (Vsg - |Vtp|)² × (1 + λ × Vsd)
        let idsSat0 = 0.5 * beta * pow(vsg - abs(vtp), 2) // Without CLM
        for (idx, vsd) in vsdValues.enumerated() {
            // Only check points in saturation: Vsd > Vsg - |Vtp|
            if vsd > vsg - abs(vtp) {
                let expectedIds = idsSat0 * (1 + lambda * vsd)
                let relError = abs(idsValues[idx] - expectedIds) / expectedIds
                #expect(relError < 0.15,
                        "CLM at Vsd=\(vsd): expected \(expectedIds), got \(idsValues[idx]), relErr=\(relError)")
            }
        }

        // Ids should increase with Vsd (channel-length modulation effect)
        let satPoints = zip(vsdValues, idsValues).filter { $0.0 > vsg - abs(vtp) }
        if satPoints.count >= 2 {
            let sorted = satPoints.sorted { $0.0 < $1.0 }
            for i in 1..<sorted.count {
                #expect(sorted[i].1 > sorted[i - 1].1 - 1e-9,
                        "Ids should increase with Vsd due to CLM")
            }
        }
    }

    // MARK: - L7: Diode Parameter Sensitivity to Is

    @Test("L7: Diode forward voltage dependence on Is parameter")
    func diodeIsParameterEffect() async throws {
        // Test that changing Is shifts the forward voltage
        // Vd ≈ n × Vt × ln(Id/Is + 1) → larger Is → lower Vd at same current
        let isValues = [1e-16, 1e-14, 1e-12, 1e-10]
        let vin = 1.0
        let r = 1000.0
        var forwardVoltages: [Double] = []

        for isVal in isValues {
            let (netlist, anode) = CircuitFactory.diodeCircuit(
                v: vin, r: r,
                diodeParams: ["is": .real(isVal), "n": .real(1.0)]
            )
            let result = try await CircuitFactory.runDC(netlist)
            forwardVoltages.append(result.voltage(at: anode))
        }

        // Forward voltage should decrease as Is increases
        for i in 1..<forwardVoltages.count {
            #expect(forwardVoltages[i] < forwardVoltages[i - 1],
                    "Vf should decrease with increasing Is: Vf(\(isValues[i]))=\(forwardVoltages[i]) should be < Vf(\(isValues[i-1]))=\(forwardVoltages[i-1])")
        }

        // Verify approximate relationship: ΔVd ≈ n×Vt × ln(Is2/Is1)
        // Each decade of Is should shift Vd by ~60mV (at room temp, n=1)
        let Vt = 0.02585
        for i in 1..<forwardVoltages.count {
            let deltaVf = forwardVoltages[i - 1] - forwardVoltages[i] // Positive: Vf decreases
            // Allow wider tolerance due to circuit loading effects
            #expect(deltaVf > 0, "Vf should decrease: delta=\(deltaVf)")
            let decades = log10(isValues[i] / isValues[i - 1])
            let expectedPerDecade = Vt * log(10) // ≈ 59.5mV per decade
            let actualPerDecade = deltaVf / decades
            #expect(abs(actualPerDecade - expectedPerDecade) < 0.03,
                    "Per-decade shift should be ~\(expectedPerDecade)V, got \(actualPerDecade)V")
        }
    }
}
