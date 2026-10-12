import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts

@main
struct DiodeResolutionContractsProbe {
    nonisolated static func run() throws {
        let environment = EvaluationEnvironment(ambient: try TemperatureKelvin(300.15), nominal: try TemperatureKelvin(295.15))
        let schema = try StandardDiodeModelSchemas().schema(for: .coreJunctionV1)
        let limits = try DiodeInputLimits(maximumAssignments: 16, maximumParameterNameBytes: 32)
        let coefficients = [DiodeScalarAssignment(name: "m", value: 0.4)]
        let modelInput = try DiodeModelInput(schema: schema, assignments: coefficients.span, environment: environment, limits: limits)
        let fields = [DiodeScalarAssignment(name: "area", value: 3), .init(name: "pj", value: 2), .init(name: "m", value: 2)]
        let input = try DiodeInstanceInput(schema: schema, assignments: fields.span, environment: environment,
                                           scale: DiodeGeometryScale(1e-6), limits: limits)
        let identity = DiodeDeclarationIdentity(declaration: 0, scope: 0, invocation: 0, sourcePath: nil,
            captureID: nil, occurrence: nil, line: nil, statementOrdinal: nil)
        let model = ResolvedDiodeModel(declaration: identity, input: modelInput, orderedAssignmentEvidence: true)
        let result = try ResolvedDiodeInstance(instance: "d1", scope: 0, invocation: 0, model: model,
            input: input, profile: .coreDiodeV1, seed: 4, evaluatorVersion: "probe-v1",
            randomGeneratorVersion: "probe-v1", orderedAssignmentEvidence: true)
        precondition(result.model.sameStorage(as: model))
        precondition(result.model.input.value(for: .gradingCoefficient) == 0.4)
        precondition(result.input.multiplicity.value == 2)
        precondition(result.input.geometry.areaFactor.value == 3)
        precondition(result.input.geometry.perimeter.value == 2e-6)
        precondition(result.environment == environment.identity)
        precondition(ResolvedDiodeModel.ownedByteCount > UInt64(MemoryLayout<DiodeModelInput>.stride))
        let other = EvaluationEnvironment(ambient: try TemperatureKelvin(310.15), nominal: environment.nominal)
        let different = try DiodeInstanceInput(schema: schema, assignments: fields.span, environment: other,
            scale: DiodeGeometryScale(1), limits: limits)
        do {
            _ = try ResolvedDiodeInstance(instance: "d2", scope: 0, invocation: 0, model: model,
                input: different, profile: .coreDiodeV1, seed: 4, evaluatorVersion: "probe-v1",
                randomGeneratorVersion: "probe-v1", orderedAssignmentEvidence: true)
            preconditionFailure("Accepted mixed evaluation environments")
        } catch let failure as DiodeSchemaFailure { precondition(failure == .environmentMismatch) }
    }
    static func main() throws { try run(); print("D3-CONTRACTS-PASS") }
}
