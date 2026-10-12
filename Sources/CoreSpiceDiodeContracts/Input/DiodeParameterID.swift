public enum DiodeParameterID: Sendable, Hashable {
    case model(DiodeModelParameterID)
    case instance(DiodeInstanceParameterID)
    public var role: DiodeParameterRole {
        switch self { case .model: .model; case .instance: .instance }
    }
}
