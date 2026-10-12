import CoreSpiceEvaluationContracts
import CoreSpiceDiodeContracts

@main
struct DiodeContractsProbe {
    static func main() {
        do {
            let environment = EvaluationEnvironment(ambient: try TemperatureCelsius(30).kelvin,
                                                   nominal: try TemperatureCelsius(27).kelvin)
            let imported = try EvaluationEnvironmentIdentity(contractVersion: 1,
                ambientKelvinBits: 303.15.bitPattern, nominalKelvinBits: 300.15.bitPattern)
            precondition(imported == environment.identity)
            let reconstructed = try EvaluationEnvironment(identity: imported)
            precondition(reconstructed == environment)
            let limits = try DiodeInputLimits(maximumAssignments: 16, maximumParameterNameBytes: 16)
            let schema = try StandardDiodeModelSchemas().schema(for: .coreJunctionV1)
            let modelFields = [DiodeScalarAssignment(name: "m", value: 0.4)]
            let instanceFields = [DiodeScalarAssignment(name: "m", value: 2), .init(name: "area", value: 3),
                                  .init(name: "pj", value: 4), .init(name: "dtemp", value: 10)]
            let model = try DiodeModelInput(schema: schema, assignments: modelFields.span,
                                           environment: environment, limits: limits)
            let instance = try DiodeInstanceInput(schema: schema, assignments: instanceFields.span,
                environment: environment, scale: DiodeGeometryScale(1e-6), limits: limits)
            precondition(model.value(for: .gradingCoefficient) == 0.4)
            precondition(model.withCoefficients { $0.count } == 12)
            precondition(instance.multiplicity.value == 2)
            precondition(instance.geometry.areaFactor.value == 3)
            precondition(instance.geometry.perimeter.value == 4e-6)
            let localTemperature = try instance.effectiveTemperature(in: environment)
            precondition(localTemperature.value == 313.15)
            do {
                _ = try DiodeInputProfile.coreDiodeV1.modelLaw(level: 3, version: nil)
                preconditionFailure("Level3 was accepted")
            } catch { precondition(error == .unsupportedLevel(3)) }
            do {
                _ = try schema.parameter(named: "js", role: .model, limits: limits)
                preconditionFailure("Unknown law coefficient was accepted")
            } catch { precondition(error == .unsupportedParameter(name: "js", role: .model)) }
            do {
                try instance.requiredFeatures.requireSupport(by: .none)
                preconditionFailure("Unavailable sidewall feature was accepted")
            } catch { precondition(error == .unsupportedFeature(.sidewall)) }
            do {
                _ = try TemperatureKelvin(0)
                preconditionFailure("Zero Kelvin was accepted")
            } catch { precondition(error == .absoluteZeroOrBelow) }
            let changed = EvaluationEnvironment(ambient: try TemperatureKelvin(304), nominal: environment.nominal)
            do {
                _ = try instance.effectiveTemperature(in: changed)
                preconditionFailure("Changed environment was accepted")
            } catch { precondition(error == .environmentMismatch) }
            print("diode-d1-contract-probe passed: identity, roles, geometry, thermal, feature and failures")
        } catch {
            preconditionFailure("Diode contract probe failed")
        }
    }
}
