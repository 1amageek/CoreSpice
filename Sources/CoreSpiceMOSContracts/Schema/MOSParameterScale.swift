public enum MOSParameterScale: Sendable, Hashable {
    case none, length, area
    public func apply(to value: Double, scale: Double) throws(MOSSchemaFailure) -> Double {
        guard value.isFinite, scale.isFinite, scale > 0 else { throw .invalidValue(name: "scale") }
        let result: Double
        switch self {
        case .none: result = value
        case .length: result = value * scale
        case .area:
            let first = value * scale
            guard first.isFinite, value <= 0 || first > 0 else { throw .invalidValue(name: "scale") }
            result = first * scale
        }
        guard result.isFinite, value <= 0 || result > 0 else { throw .invalidValue(name: "scale") }
        return result
    }
}
