/// The caller owns circuit solving, timestep selection and acceptance.
public enum BSIM3Analysis: Sendable {
    case dc
    case ac(angularFrequency: Double)
    case backwardEuler(timeStep: Double)
    case trapezoidal(timeStep: Double)
}
