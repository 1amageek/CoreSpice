import Testing
import CoreSpiceEvaluationContracts

@Suite("Evaluation environment contracts", .timeLimit(.minutes(1)))
struct EnvironmentTests {
    @Test func unitConversionAndDelta() throws {
        let celsius = try TemperatureCelsius(30)
        #expect(celsius.kelvin.value == 303.15)
        #expect(try celsius.kelvin.celsius().value == 30)
        #expect(try celsius.kelvin.applying(TemperatureDelta(10)).value == 313.15)
        #expect(try TemperatureDelta(-0.0).value.bitPattern == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -0.0, -1])
    func rejectsInvalidKelvin(_ value: Double) {
        #expect(throws: TemperatureFailure.self) { try TemperatureKelvin(value) }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -273.15, -300])
    func rejectsInvalidCelsius(_ value: Double) {
        #expect(throws: TemperatureFailure.self) { try TemperatureCelsius(value) }
    }

    @Test func representableBoundaryAndFailedConversion() throws {
        let above = try TemperatureCelsius((-273.15).nextUp)
        #expect(above.kelvin.value > 0)
        let tiny = try TemperatureKelvin(Double.leastNonzeroMagnitude)
        #expect(throws: TemperatureFailure.conversionNotRepresentable) { try tiny.celsius() }
        let fractional = try TemperatureKelvin(0.1)
        #expect(try fractional.celsius().kelvin == fractional)
        #expect(throws: TemperatureFailure.absoluteZeroOrBelow) {
            try TemperatureKelvin(1).applying(TemperatureDelta(-1))
        }
        #expect(throws: TemperatureFailure.nonFinite) {
            try TemperatureKelvin(Double.greatestFiniteMagnitude).applying(TemperatureDelta(.greatestFiniteMagnitude))
        }
        #expect(throws: TemperatureFailure.nonFinite) { try TemperatureDelta(.nan) }
    }

    @Test func stableIdentityAndReconstruction() throws {
        let environment = EvaluationEnvironment(ambient: try TemperatureCelsius(30).kelvin,
                                               nominal: try TemperatureKelvin(300.15))
        let identity = environment.identity
        #expect(identity.contractVersion == 1)
        #expect(identity.ambientKelvinBits == 303.15.bitPattern)
        #expect(identity.nominalKelvinBits == 300.15.bitPattern)
        let imported = try EvaluationEnvironmentIdentity(contractVersion: 1,
            ambientKelvinBits: 303.15.bitPattern, nominalKelvinBits: 300.15.bitPattern)
        #expect(imported == identity)
        #expect(try EvaluationEnvironment(identity: imported) == environment)
        let changedAmbient = EvaluationEnvironment(ambient: try TemperatureKelvin(303.15.nextUp), nominal: environment.nominal)
        let changedNominal = EvaluationEnvironment(ambient: environment.ambient, nominal: try TemperatureKelvin(301))
        #expect(changedAmbient.identity != identity)
        #expect(changedNominal.identity != identity)
    }

    @Test func forgedIdentityRejected() {
        #expect(throws: TemperatureFailure.unsupportedIdentityVersion(2)) {
            try EvaluationEnvironmentIdentity(contractVersion: 2, ambientKelvinBits: 300.15.bitPattern,
                                             nominalKelvinBits: 300.15.bitPattern)
        }
        for bits in [Double.nan.bitPattern, Double.infinity.bitPattern, (-0.0).bitPattern, 0] {
            #expect(throws: TemperatureFailure.self) {
                try EvaluationEnvironmentIdentity(contractVersion: 1, ambientKelvinBits: bits,
                                                 nominalKelvinBits: 300.15.bitPattern)
            }
            #expect(throws: TemperatureFailure.self) {
                try EvaluationEnvironmentIdentity(contractVersion: 1, ambientKelvinBits: 300.15.bitPattern,
                                                 nominalKelvinBits: bits)
            }
        }
    }
}
