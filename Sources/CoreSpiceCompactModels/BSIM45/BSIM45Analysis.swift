public enum BSIM45Analysis: Sendable {
    case dc
    case ac(angularFrequency: Double)
    case backwardEuler(timeStep: Double)
    case trapezoidal(timeStep: Double)
}
