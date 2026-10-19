/// The continuous physical equation is F(x, t) + dQ(x, t)/dt = 0.
package enum ContinuousEquationPlane: Sendable, Equatable {
    case staticResidual
    case charge
}
