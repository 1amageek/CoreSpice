import CoreSpiceEvaluationContracts

public struct DiodeParameterDefinition: Sendable, Hashable {
    public let id: DiodeParameterID
    public let sourceName: String
    public let sourceUnit: DiodeParameterUnit
    public let canonicalUnit: DiodeParameterUnit
    public let domain: DiodeParameterDomain
    public let defaultValue: DiodeParameterDefault

    /// Validates source scalars and converts thermal units; geometry remains unscaled.
    func validatedInputValue(from supplied: Double) throws(DiodeSchemaFailure) -> Double {
        guard supplied.isFinite else { throw .invalidValue(id) }
        switch domain {
        case .positive: guard supplied > 0 else { throw .invalidValue(id) }
        case .nonNegative: guard supplied >= 0 else { throw .invalidValue(id) }
        case .grading: guard supplied >= 0, supplied < 1 else { throw .invalidValue(id) }
        case .finite: break
        case .absoluteCelsius:
            do { return try TemperatureCelsius(supplied).kelvin.value }
            catch { throw .temperature(id, error) }
        }
        return supplied == 0 ? 0 : supplied
    }
}
