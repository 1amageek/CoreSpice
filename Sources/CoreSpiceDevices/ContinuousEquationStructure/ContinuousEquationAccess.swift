/// Conservative support of the continuous F/Q law, not a companion matrix.
package enum ContinuousEquationAccess: Sendable, Equatable {
    case readCoordinate
    case writeStaticResidual
    case writeCharge
}
