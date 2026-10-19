package enum ContinuousEquationStructureFailure: Error, Sendable, Equatable {
    case invalidBinding(device: String)
    case nonFiniteCoefficient(device: String)
    case invalidSourceLaw(device: String)
}
