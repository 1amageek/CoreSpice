import CoreSpiceEvaluationContracts

/// Checked scalar instance input, separate from model coefficients and numerical preparation.
public struct DiodeInstanceInput: Sendable {
    public let schemaIdentity: DiodeSchemaIdentity
    public let environmentIdentity: EvaluationEnvironmentIdentity
    public let rawGeometry: RawDiodeGeometry
    public let geometry: DiodeNormalizedGeometry
    public let multiplicity: DiodeParallelMultiplicity
    public let thermal: DiodeThermalInput
    private let supplied: UInt8

    public init(schema: DiodeModelSchema, assignments: Span<DiodeScalarAssignment>,
                environment: borrowing EvaluationEnvironment, scale: DiodeGeometryScale,
                limits: DiodeInputLimits) throws(DiodeSchemaFailure) {
        guard assignments.count <= limits.maximumAssignments else { throw .assignmentLimit }
        var values = InlineArray<5, Double?>(repeating: nil)
        var mask: UInt8 = 0
        for assignment in assignments {
            let definition = try schema.parameter(named: assignment.name, role: .instance, limits: limits)
            guard case .instance(let id) = definition.id else { throw .schemaUnavailable(schema.law) }
            let bit: UInt8 = 1 << id.rawValue
            guard mask & bit == 0 else { throw .duplicateParameter(definition.id) }
            values[id.rawValue] = try definition.validatedInputValue(from: assignment.value)
            mask |= bit
        }
        if values[DiodeInstanceParameterID.temperature.rawValue] != nil,
           values[DiodeInstanceParameterID.temperatureDelta.rawValue] != nil { throw .conflictingTemperatures }
        let area: DiodeAreaFactor?
        if let value = values[DiodeInstanceParameterID.areaFactor.rawValue] { area = try .init(value) }
        else { area = nil }
        let perimeter: DiodeInputPerimeter?
        if let value = values[DiodeInstanceParameterID.perimeter.rawValue] { perimeter = try .init(value) }
        else { perimeter = nil }
        rawGeometry = .init(area: area, perimeter: perimeter)
        geometry = try rawGeometry.normalized(by: scale, schema: schema)
        let multiplier: Double
        if let suppliedMultiplier = values[DiodeInstanceParameterID.parallelMultiplicity.rawValue] {
            multiplier = suppliedMultiplier
        } else { multiplier = try schema.constantDefault(for: .instance(.parallelMultiplicity)) }
        multiplicity = try .init(multiplier)
        if let value = values[DiodeInstanceParameterID.temperature.rawValue] {
            do { thermal = .absolute(try TemperatureKelvin(value)) }
            catch { throw .temperature(.instance(.temperature), error) }
        } else if let value = values[DiodeInstanceParameterID.temperatureDelta.rawValue] {
            do { thermal = .offset(try TemperatureDelta(value)) }
            catch { throw .temperature(.instance(.temperatureDelta), error) }
        } else { thermal = .ambient }
        do { _ = try thermal.effectiveTemperature(in: environment) }
        catch { throw .temperature(.instance(.temperatureDelta), error) }
        supplied = mask; schemaIdentity = schema.identity; environmentIdentity = environment.identity
    }
    public func origin(for id: DiodeInstanceParameterID) -> DiodeValueOrigin {
        if supplied & (1 << id.rawValue) != 0 { return .supplied }
        return id == .temperature ? .environmentDefault : .schemaDefault
    }
    public func validateEnvironment(_ environment: borrowing EvaluationEnvironment) throws(DiodeSchemaFailure) {
        guard environment.identity == environmentIdentity else { throw .environmentMismatch }
    }
    public func effectiveTemperature(in environment: borrowing EvaluationEnvironment) throws(DiodeSchemaFailure) -> TemperatureKelvin {
        try validateEnvironment(environment)
        do { return try thermal.effectiveTemperature(in: environment) }
        catch { throw .temperature(.instance(.temperatureDelta), error) }
    }
    public var requiredFeatures: DiodeFeatureSet {
        geometry.perimeter.value > 0 ? DiodeFeatureSet(.sidewall) : .none
    }
}
