import CoreSpiceEvaluationContracts
import CoreSpiceDiodeContracts

@main
struct DiodePreparationContractsProbe {
    static func main() throws {
        let environment = EvaluationEnvironment(ambient: try .init(300.15), nominal: try .init(310))
        let schema = DiodeModelSchema(law: .coreJunctionV1)
        let limits = try DiodeInputLimits(maximumAssignments: 32, maximumParameterNameBytes: 64)
        let modelAssignments = [DiodeScalarAssignment(name: "m", value: 0.4), .init(name: "tnom", value: 42)]
        let instanceAssignments = [DiodeScalarAssignment(name: "m", value: 2), .init(name: "area", value: 3),
            .init(name: "dtemp", value: 5)]
        let model = try DiodeModelInput(schema: schema, assignments: modelAssignments.span,
            environment: environment, limits: limits)
        let input = try DiodeInstanceInput(schema: schema, assignments: instanceAssignments.span,
            environment: environment, scale: .init(1e-6), limits: limits)
        let resolved = try ResolvedDiodeInstance.sourceFree(instance: "D1", model: model, input: input, profile: .coreDiodeV1)
        let preparation = try DiodePreparationInput(resolved: resolved, environment: environment,
            analyses: [.dc, .ac], anodeNodeID: 1, cathodeNodeID: 0)
        precondition(resolved.model.declaration.sourcePath == nil && !resolved.orderedAssignmentEvidence)
        precondition(input.geometry.areaFactor.value == 3 && input.multiplicity.value == 2)
        precondition(model.value(for: .gradingCoefficient) == 0.4)
        let effectiveTemperature = try input.effectiveTemperature(in: environment)
        let identity = DiodePreparationIdentity(input: preparation, effectiveTemperature: effectiveTemperature,
            implementationIdentity: "CoreSpice.D4.ValueProbe.v1")
        let policy = try DiodePreparationLimits(maximumRetainedBytes: 4096, maximumTemporaryBytes: 4096,
            maximumWorkUnits: 1000)
        let receipt = try DiodePreparationReceipt(identity: identity, requiredFeatures: .none,
            retainedBytes: 128, peakTemporaryBytes: 64, workUnits: 32, limits: policy)
        precondition(receipt.identity.environment == environment.identity && receipt.coldSetupCount == 1)
        precondition(receipt.identity.effectiveTemperature.value == 305.15 && receipt.auxiliaryNodeCount == 0)
        let changed = try DiodePreparationInput(resolved: resolved, environment: environment,
            analyses: [.dc, .ac], anodeNodeID: 0, cathodeNodeID: 1)
        let changedIdentity = DiodePreparationIdentity(input: changed, effectiveTemperature: effectiveTemperature,
            implementationIdentity: "CoreSpice.D4.ValueProbe.v1")
        precondition(identity != changedIdentity)
        do {
            _ = try DiodePreparationInput(resolved: resolved,
                environment: .init(ambient: try .init(301), nominal: environment.nominal),
                analyses: [.dc], anodeNodeID: 1, cathodeNodeID: 0)
            fatalError("Mixed environment admitted")
        } catch DiodePreparationFailure.schema(.environmentMismatch) {}
        do {
            _ = try DiodePreparationInput(resolved: resolved, environment: environment,
                analyses: .init(rawValue: 128), anodeNodeID: 1, cathodeNodeID: 0)
            fatalError("Unknown analysis bit admitted")
        } catch DiodePreparationFailure.invalidConditions {}
        do {
            _ = try DiodePreparationReceipt(identity: identity, requiredFeatures: .none,
                retainedBytes: 4097, peakTemporaryBytes: 64, workUnits: 32, limits: policy)
            fatalError("Receipt capacity admitted")
        } catch DiodePreparationFailure.capacityExceeded {}
        do {
            _ = try ResolvedDiodeInstance.sourceFree(instance: "D1", model: model, input: input, profile: .genericDiodeV1)
            fatalError("Mismatched law admitted")
        } catch DiodeSchemaFailure.schemaUnavailable(.coreJunctionV1) {}
        let genericLaw = try DiodeInputProfile.genericDiodeV1.modelLaw(level: 1, version: nil)
        precondition(genericLaw == .genericJunctionV1)
        print("D4-PREPARATION-CONTRACTS-PASS")
    }
}
