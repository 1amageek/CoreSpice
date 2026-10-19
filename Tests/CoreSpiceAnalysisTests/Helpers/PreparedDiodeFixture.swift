import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts
import CoreSpiceIR
import CoreSpiceDevices

/// Explicit checked generic fixture; flat test dictionaries are input-boundary data only.
struct PreparedDiodeFixture {
    func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        let owner = try Self.prepare(instance: instance, conditions: context.operatingConditions)
        let bound = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
            parameters: instance.parameters, model: instance.model, diode: .prepared(owner.receipt),
            modelConsumption: instance.modelConsumption)
        return try owner.bind(instance: bound, context: &context)
    }
    static func prepare(instance: Instance, conditions: OperatingConditions = .nominal,
                        profile: DiodeInputProfile = .genericDiodeV1,
                        limits: DiodePreparationLimits? = nil,
                        control: any DiodePreparationControlling = DiodeFixtureControl()) throws -> NativePreparedDiodeDevice {
        let environment = EvaluationEnvironment(ambient: try .init(conditions.temperatureKelvin),
            nominal: try .init(conditions.nominalTemperatureKelvin))
        let schema = DiodeModelSchema(law: try profile.modelLaw(level: nil, version: nil))
        var assignments: [DiodeScalarAssignment] = []
        for (key, value) in instance.parameters.sorted(by: { $0.key < $1.key }) {
            guard case .real(let number) = value else { throw DiodeSchemaFailure.invalidValue(.model(.saturationCurrent)) }
            assignments.append(.init(name: key == "tnom_k" ? "tnom" : key,
                value: key == "tnom_k" ? number - 273.15 : number))
        }
        let inputLimits = try DiodeInputLimits(maximumAssignments: 32, maximumParameterNameBytes: 64)
        let model = try DiodeModelInput(schema: schema, assignments: assignments.span,
            environment: environment, limits: inputLimits)
        let inputs: [DiodeScalarAssignment] = []
        let input = try DiodeInstanceInput(schema: schema, assignments: inputs.span, environment: environment,
            scale: .init(1), limits: inputLimits)
        let resolved = try ResolvedDiodeInstance.sourceFree(instance: instance.name, model: model, input: input, profile: profile)
        guard instance.nodes.count == 2 else { throw DiodePreparationFailure.topologyMismatch }
        return try NativeDiodeDevicePreparer().prepare(.init(resolved: resolved, environment: environment,
            analyses: .all, anodeNodeID: instance.nodes[0].id, cathodeNodeID: instance.nodes[1].id),
            limits: limits ?? .init(maximumRetainedBytes: 65536, maximumTemporaryBytes: 4096, maximumWorkUnits: 1000),
            control: control)
    }
}

struct DiodeFixtureControl: DiodePreparationControlling {
    func checkCancellation() throws(DiodePreparationFailure) {}
    func chargeWork(_ units: UInt64) throws(DiodePreparationFailure) {}
}
