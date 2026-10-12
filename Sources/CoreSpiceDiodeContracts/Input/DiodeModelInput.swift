import CoreSpiceEvaluationContracts

/// Checked scalar model input; source declaration resolution belongs to Lowering.
public struct DiodeModelInput: Sendable {
    public let schemaIdentity: DiodeSchemaIdentity
    public let environmentIdentity: EvaluationEnvironmentIdentity
    public let nominalTemperature: TemperatureKelvin
    private let storage: InlineArray<12, Double?>
    private let supplied: UInt16

    public init(schema: DiodeModelSchema, assignments: Span<DiodeScalarAssignment>,
                environment: borrowing EvaluationEnvironment, limits: DiodeInputLimits) throws(DiodeSchemaFailure) {
        guard assignments.count <= limits.maximumAssignments else { throw .assignmentLimit }
        var values = InlineArray<12, Double?>(repeating: nil)
        for index in 0..<12 {
            guard let id = DiodeModelParameterID(rawValue: index) else { throw .schemaUnavailable(schema.law) }
            switch schema.definition(for: .model(id)).defaultValue {
            case .constant(let value): values[index] = value
            case .environmentNominal: values[index] = environment.nominal.value
            case .disabled: break
            case .environmentAmbient: throw .schemaUnavailable(schema.law)
            }
        }
        var mask: UInt16 = 0
        for assignment in assignments {
            let definition = try schema.parameter(named: assignment.name, role: .model, limits: limits)
            guard case .model(let id) = definition.id else { throw .schemaUnavailable(schema.law) }
            let bit: UInt16 = 1 << id.rawValue
            guard mask & bit == 0 else { throw .duplicateParameter(definition.id) }
            values[id.rawValue] = try definition.validatedInputValue(from: assignment.value)
            mask |= bit
        }
        guard let nominal = values[DiodeModelParameterID.nominalTemperature.rawValue] else {
            throw .schemaUnavailable(schema.law)
        }
        do { nominalTemperature = try TemperatureKelvin(nominal) }
        catch { throw .temperature(.model(.nominalTemperature), error) }
        storage = values; supplied = mask
        schemaIdentity = schema.identity; environmentIdentity = environment.identity
    }

    public func validateEnvironment(_ environment: borrowing EvaluationEnvironment) throws(DiodeSchemaFailure) {
        guard environment.identity == environmentIdentity else { throw .environmentMismatch }
    }
    public func value(for id: DiodeModelParameterID) -> Double? { storage[id.rawValue] }
    public func origin(for id: DiodeModelParameterID) -> DiodeValueOrigin {
        if supplied & (1 << id.rawValue) != 0 { return .supplied }
        return id == .nominalTemperature ? .environmentDefault : .schemaDefault
    }
    public borrowing func withCoefficients<Result>(_ body: (Span<Double?>) -> Result) -> Result {
        body(storage.span)
    }
    public var requiredFeatures: DiodeFeatureSet {
        var result = DiodeFeatureSet()
        if let value = value(for: .seriesResistance), value > 0 { result = result.adding(.seriesResistance) }
        if value(for: .breakdownVoltage) != nil { result = result.adding(.breakdown) }
        if let value = value(for: .junctionCapacitance), value > 0 { result = result.adding(.depletionCharge) }
        if let value = value(for: .transitTime), value > 0 { result = result.adding(.diffusionCharge) }
        return result
    }
    public func disposition(for id: DiodeModelParameterID) -> DiodeParameterDisposition {
        if (id == .breakdownCurrent || id == .breakdownVoltage), value(for: .breakdownVoltage) == nil {
            return .inactiveBreakdownDisabled
        }
        return .active
    }
}
