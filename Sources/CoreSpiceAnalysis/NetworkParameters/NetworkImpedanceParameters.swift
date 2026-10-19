/// A singular admittance has no finite inverse; it remains a valid Y/S observation.
public enum NetworkImpedanceParameters: Sendable, Equatable {
    case defined(NetworkParameterMatrix)
    case undefined(Reason)

    public enum Reason: String, Sendable, Equatable {
        case singularAdmittance
    }
}
