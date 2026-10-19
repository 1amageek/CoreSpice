import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts

/// Checked numerical replacement retaining the original source basis, not source evaluation evidence.
public struct DiodeNumericPerturbation: Sendable {
    public let basis: ResolvedDiodeInstance
    public let parameter: DiodeParameterID
    public let value: Double
    public let resolved: ResolvedDiodeInstance

    public init(basis: ResolvedDiodeInstance, parameter: DiodeParameterID, value: Double) throws {
        let environment = try Self.environment(basis)
        let schema = DiodeModelSchema(law: basis.model.input.schemaIdentity.law)
        let limits = try DiodeInputLimits(maximumAssignments: 17, maximumParameterNameBytes: 64)
        var modelAssignments: [DiodeScalarAssignment] = []
        for index in 0..<12 {
            guard let id = DiodeModelParameterID(rawValue: index) else { continue }
            let selected = parameter == .model(id)
            guard selected || basis.model.input.origin(for: id) == .supplied else { continue }
            guard let number = selected ? value : basis.model.input.value(for: id) else { continue }
            let sourceValue = id == .nominalTemperature ? number - 273.15 : number
            modelAssignments.append(.init(name: schema.definition(for: .model(id)).sourceName, value: sourceValue))
        }
        var instanceAssignments: [DiodeScalarAssignment] = []
        for index in 0..<5 {
            guard let id = DiodeInstanceParameterID(rawValue: index) else { continue }
            let selected = parameter == .instance(id)
            guard selected || basis.input.origin(for: id) == .supplied else { continue }
            guard let number = selected ? value : Self.instanceValue(basis.input, id: id) else { continue }
            let sourceValue = id == .temperature ? number - 273.15 : number
            instanceAssignments.append(.init(name: schema.definition(for: .instance(id)).sourceName, value: sourceValue))
        }
        let modelInput = try DiodeModelInput(schema: schema, assignments: modelAssignments.span,
            environment: environment, limits: limits)
        // Zero/absent perimeter has identical normalization at any positive scale.
        let scale: Double
        if let perimeter = basis.input.rawGeometry.perimeter, perimeter.value > 0 {
            scale = basis.input.geometry.perimeter.value / perimeter.value
        } else { scale = 1 }
        let instanceInput = try DiodeInstanceInput(schema: schema, assignments: instanceAssignments.span,
            environment: environment, scale: .init(scale), limits: limits)
        let model = ResolvedDiodeModel(declaration: basis.model.declaration, input: modelInput,
            orderedAssignmentEvidence: false)
        resolved = try .init(instance: basis.instance, scope: basis.scope, invocation: basis.invocation,
            model: model, input: instanceInput, profile: basis.profile, seed: basis.seed,
            evaluatorVersion: basis.evaluatorVersion + ".numeric-perturbation.v1",
            randomGeneratorVersion: basis.randomGeneratorVersion, orderedAssignmentEvidence: false)
        self.basis = basis; self.parameter = parameter; self.value = value
    }
    public static func environment(_ resolved: ResolvedDiodeInstance) throws -> EvaluationEnvironment {
        try .init(ambient: .init(Double(bitPattern: resolved.environment.ambientKelvinBits)),
                  nominal: .init(Double(bitPattern: resolved.environment.nominalKelvinBits)))
    }
    public static func instanceValue(_ input: DiodeInstanceInput, id: DiodeInstanceParameterID) -> Double? {
        switch id {
        case .areaFactor: input.rawGeometry.area?.value ?? input.geometry.areaFactor.value
        case .perimeter: input.rawGeometry.perimeter?.value
        case .parallelMultiplicity: input.multiplicity.value
        case .temperature:
            if case .absolute(let temperature) = input.thermal { temperature.value } else { nil }
        case .temperatureDelta:
            if case .offset(let delta) = input.thermal { delta.value } else { nil }
        }
    }
}
