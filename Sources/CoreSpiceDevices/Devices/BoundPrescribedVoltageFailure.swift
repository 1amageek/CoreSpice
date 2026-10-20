/// A local external-coordinate equation failure, without a history or root verdict.
package enum BoundPrescribedVoltageFailure: Error, Sendable {
    case invalidBinding
    case invalidEndpoint
    case invalidTime
    case invalidDomain
    case missingCoordinate
    case binding(any Error)
    case numerical(any Error)
    case control(any Error)
    case callback(any Error)
}
