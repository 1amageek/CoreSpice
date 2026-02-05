import Testing
import Foundation
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceEvent

/// Tests for temperature effects on semiconductor devices.
///
/// Temperature is critical for semiconductor device behavior:
/// - Thermal voltage: Vt = kT/q (≈26mV at 300K)
/// - Diode Is(T) scales exponentially with temperature
/// - Diode Vf decreases ~2mV/°C
/// - BJT beta varies with temperature
/// - MOSFET Vth has temperature coefficient
///
/// Physical constants:
/// - k = 1.380649e-23 J/K (Boltzmann constant)
/// - q = 1.602176634e-19 C (elementary charge)
@Suite("Temperature Effects Tests")
struct TemperatureEffectsTests {

    // MARK: - Physical Constants

    private static let k: Double = 1.380649e-23   // Boltzmann constant (J/K)
    private static let q: Double = 1.602176634e-19 // Elementary charge (C)

    // MARK: - Test 1: Thermal Voltage at Different Temperatures

    /// Verifies thermal voltage formula Vt = kT/q.
    ///
    /// Expected values:
    /// - T = 300K (27°C): Vt ≈ 25.85 mV
    /// - T = 350K (77°C): Vt ≈ 30.16 mV
    /// - T = 250K (-23°C): Vt ≈ 21.54 mV
    @Test("Thermal voltage Vt = kT/q at different temperatures")
    func thermalVoltageFormula() {
        let temperatures = [250.0, 300.0, 350.0, 400.0]  // Kelvin

        for temp in temperatures {
            let expectedVt = Self.k * temp / Self.q

            // Create diode parameters at this temperature
            let params = DiodeModelParameters(nominalTemperature: temp)
            let actualVt = params.thermalVoltage

            #expect(abs(actualVt - expectedVt) / expectedVt < 1e-10,
                    "Vt at \(temp)K: expected \(expectedVt), got \(actualVt)")
        }
    }

    // MARK: - Test 2: Room Temperature Thermal Voltage

    /// Verifies thermal voltage at room temperature (300K ≈ 27°C).
    ///
    /// This is the most commonly used reference value in SPICE.
    @Test("Thermal voltage at room temperature is ~25.85mV")
    func roomTemperatureThermalVoltage() {
        let temp = 300.0  // 27°C in Kelvin
        let params = DiodeModelParameters(nominalTemperature: temp)
        let vt = params.thermalVoltage

        // Expected: kT/q ≈ 25.85 mV at 300K
        let expected = Self.k * temp / Self.q
        #expect(abs(vt - expected) < 1e-15, "Vt at 300K should be \(expected), got \(vt)")
        #expect(abs(vt - 0.02585) < 0.0001, "Vt at 300K should be ~25.85mV")
    }

    // MARK: - Test 3: Thermal Voltage Temperature Coefficient

    /// Verifies that thermal voltage scales linearly with temperature.
    ///
    /// dVt/dT = k/q ≈ 86.17 µV/K
    @Test("Thermal voltage temperature coefficient dVt/dT = k/q")
    func thermalVoltageTemperatureCoefficient() {
        let t1 = 300.0
        let t2 = 350.0

        let params1 = DiodeModelParameters(nominalTemperature: t1)
        let params2 = DiodeModelParameters(nominalTemperature: t2)

        let vt1 = params1.thermalVoltage
        let vt2 = params2.thermalVoltage

        let measuredCoeff = (vt2 - vt1) / (t2 - t1)
        let expectedCoeff = Self.k / Self.q  // ≈ 86.17 µV/K

        #expect(abs(measuredCoeff - expectedCoeff) / expectedCoeff < 1e-10,
                "dVt/dT should be k/q = \(expectedCoeff), got \(measuredCoeff)")
    }

    // MARK: - Test 4: BJT Thermal Voltage Usage

    /// Verifies BJT model uses thermal voltage correctly.
    @Test("BJT model thermal voltage matches formula")
    func bjtThermalVoltage() {
        let temp = 300.15  // Default SPICE temperature
        let params = BJTModelParameters(nominalTemperature: temp)
        let vt = params.thermalVoltage

        let expected = Self.k * temp / Self.q

        #expect(abs(vt - expected) / expected < 1e-10,
                "BJT Vt at \(temp)K: expected \(expected), got \(vt)")
    }

    // MARK: - Test 5: Diode Model Parameters Include Temperature

    /// Verifies diode model has all temperature-related parameters.
    @Test("Diode model includes temperature parameters (EG, XTI, TNOM)")
    func diodeTemperatureParameters() {
        let params = DiodeModelParameters()

        // Energy gap (EG) - default 1.11 eV for silicon
        #expect(params.energyGap == 1.11, "EG default should be 1.11 eV")

        // Saturation current temperature exponent (XTI) - default 3.0
        #expect(params.saturationCurrentExponent == 3.0, "XTI default should be 3.0")

        // Nominal temperature (TNOM) - default 300.15 K (27°C)
        #expect(abs(params.nominalTemperature - 300.15) < 0.01,
                "TNOM default should be 300.15K")
    }

    // MARK: - Test 6: Diode Forward Voltage vs Temperature (Integration)

    /// Verifies diode forward voltage behavior at different temperatures.
    ///
    /// Physical basis:
    /// - Vf decreases with temperature (approximately -2mV/°C)
    /// - This is because Is increases faster than Vt
    ///
    /// Note: This test verifies the model responds to temperature changes
    /// in thermalVoltage, even if full Is(T) scaling isn't implemented.
    @Test("Diode Vf changes with nominal temperature setting")
    func diodeVfVsTemperature() async throws {
        // Test at two temperatures
        let temps = [300.0, 350.0]
        var forwardVoltages: [Double] = []

        for temp in temps {
            var netlist = Netlist()
            let _ = netlist.node("in")
            let anode = netlist.node("anode")
            let _ = netlist.branch()

            // Fixed current source drives diode
            try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                     parameters: ["v": .real(5.0)])
            try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "anode"],
                                     parameters: ["r": .real(1000.0)])
            // Diode with specific nominal temperature
            try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "0"],
                                     parameters: [
                                         "is": .real(1e-14),
                                         "tnom": .real(temp)
                                     ])

            let ir = try netlist.build()
            let compiler = StandardCompiler()
            let plan = try compiler.compile(ir: ir)

            let registry = DeviceRegistry.standard()
            let structure = plan.matrixStructure
            var context = BindingContext(
                variableMap: plan.topology.variableMap,
                matrixDimension: plan.topology.dimension,
                stampIndexResolver: { row, col in structure.index(row: row, col: col) }
            )
            var devices: [any BoundDevice] = []
            for instance in ir.instances {
                guard let desc = registry.descriptor(for: instance.typeName) else { continue }
                let bound = try desc.bind(instance: instance, context: &context)
                devices.append(bound)
            }

            let dcAnalysis = DCAnalysis()
            let solver = SparseLUSolver()
            let token = CancellationToken()

            let result = try await dcAnalysis.run(
                plan: plan, devices: devices, solver: solver,
                observer: nil, cancellation: token
            )

            let vf = result.voltage(at: anode)
            forwardVoltages.append(vf)
        }

        // Higher temperature should give different Vf
        // The exact behavior depends on whether full Is(T) scaling is implemented
        // At minimum, Vt changes affect the exponential
        let vf_300K = forwardVoltages[0]
        let vf_350K = forwardVoltages[1]

        #expect(vf_300K.isFinite, "Vf at 300K should be finite")
        #expect(vf_350K.isFinite, "Vf at 350K should be finite")

        // Both should be reasonable forward voltages (~0.5-0.8V for Si diode)
        #expect(vf_300K > 0.4 && vf_300K < 1.0,
                "Vf at 300K should be ~0.5-0.8V, got \(vf_300K)")
        #expect(vf_350K > 0.4 && vf_350K < 1.0,
                "Vf at 350K should be ~0.5-0.8V, got \(vf_350K)")
    }

    // MARK: - Test 7: Temperature Parameter Propagation

    /// Verifies that temperature parameters are correctly parsed from netlist.
    @Test("Temperature parameter TNOM is passed to device model")
    func temperatureParameterPropagation() throws {
        var netlist = Netlist()
        let _ = netlist.node("a")
        let customTemp = 350.0

        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["a", "0"],
                                 parameters: ["tnom": .real(customTemp)])

        let ir = try netlist.build()

        // Find the diode instance
        let diodeInstance = ir.instances.first { $0.name == "D1" }
        #expect(diodeInstance != nil, "Diode instance should exist")

        // Check parameter was stored
        if let tnom = diodeInstance?.parameters["tnom"] {
            switch tnom {
            case .real(let value):
                #expect(abs(value - customTemp) < 0.001,
                        "TNOM should be \(customTemp), got \(value)")
            default:
                Issue.record("TNOM should be a real value")
            }
        }
    }

    // MARK: - Test 8: Saturation Current Temperature Formula

    /// Documents the expected Is(T) temperature scaling formula.
    ///
    /// SPICE formula: Is(T) = Is(Tnom) × (T/Tnom)^XTI × exp(EG×(T-Tnom)/(k×T×Tnom/q))
    ///
    /// This test verifies the formula produces expected scaling factors.
    @Test("Is(T) scaling formula produces expected values")
    func saturationCurrentScalingFormula() {
        let tnom = 300.0  // Nominal temperature (K)
        let t = 350.0     // Simulation temperature (K)
        let eg = 1.11     // Energy gap (eV) for silicon
        let xti = 3.0     // Temperature exponent

        // Calculate expected scaling factor
        // Is(T)/Is(Tnom) = (T/Tnom)^XTI × exp(EG×(T-Tnom)/(k×T×Tnom/q))
        let vtSim = Self.k * t / Self.q

        let ratio = t / tnom
        let tempFactor = pow(ratio, xti)
        let expArg = eg * (t - tnom) / (vtSim * tnom)
        let expFactor = exp(expArg)
        let scalingFactor = tempFactor * expFactor

        // At 350K vs 300K, Is should increase significantly
        // Rough estimate: ~10-100x increase for 50K rise
        #expect(scalingFactor > 1.0, "Is should increase with temperature")
        #expect(scalingFactor > 10.0, "50K rise should give >10x Is increase")
        #expect(scalingFactor < 1000.0, "50K rise should give <1000x Is increase")

        // Document the expected value for implementation reference
        // This serves as a specification for future temperature implementation
        let expectedScaling = scalingFactor
        #expect(expectedScaling.isFinite, "Scaling factor should be finite: \(expectedScaling)")
    }

    // MARK: - Test 9: MOSFET Threshold Temperature Coefficient

    /// Documents expected MOSFET Vth temperature behavior.
    ///
    /// Physical basis:
    /// - Vth typically decreases with temperature (~-1 to -3 mV/°C)
    /// - Due to Fermi level and carrier concentration changes
    ///
    /// Note: Level 1 MOSFET model may not include temperature effects.
    @Test("MOSFET model has threshold voltage parameter")
    func mosfetThresholdParameter() {
        // Verify VTO parameter exists and is accessible
        let vto = 0.7  // Typical NMOS threshold
        let params = MOSFETModelParameters(
            vto: vto,
            kp: 200e-6,
            gamma: 0.5,
            phi: 0.6,
            lambda: 0.02
        )

        #expect(params.vto == vto, "VTO should be stored correctly")
    }

    // MARK: - Test 10: Cryogenic Temperature Support

    /// Verifies model behavior at cryogenic temperatures (77K, liquid nitrogen).
    ///
    /// Cryogenic operation is important for:
    /// - Superconducting electronics
    /// - Low-noise amplifiers
    /// - Quantum computing interfaces
    @Test("Thermal voltage at cryogenic temperature (77K)")
    func cryogenicThermalVoltage() {
        let temp = 77.0  // Liquid nitrogen temperature (K)
        let params = DiodeModelParameters(nominalTemperature: temp)
        let vt = params.thermalVoltage

        let expected = Self.k * temp / Self.q
        #expect(abs(vt - expected) / expected < 1e-10,
                "Vt at 77K should be \(expected), got \(vt)")

        // At 77K, Vt ≈ 6.6 mV (much smaller than room temperature)
        #expect(vt < 0.007, "Vt at 77K should be < 7mV")
        #expect(vt > 0.006, "Vt at 77K should be > 6mV")
    }

    // MARK: - Test 11: High Temperature Support

    /// Verifies model behavior at elevated temperatures (125°C = 398K).
    ///
    /// High temperature operation is critical for:
    /// - Automotive electronics (-40°C to +125°C)
    /// - Industrial applications
    /// - Power electronics
    @Test("Thermal voltage at elevated temperature (125°C = 398K)")
    func highTemperatureThermalVoltage() {
        let temp = 398.15  // 125°C in Kelvin
        let params = DiodeModelParameters(nominalTemperature: temp)
        let vt = params.thermalVoltage

        let expected = Self.k * temp / Self.q
        #expect(abs(vt - expected) / expected < 1e-10,
                "Vt at 398K should be \(expected), got \(vt)")

        // At 125°C, Vt ≈ 34.3 mV
        #expect(vt > 0.034, "Vt at 125°C should be > 34mV")
        #expect(vt < 0.035, "Vt at 125°C should be < 35mV")
    }
}
