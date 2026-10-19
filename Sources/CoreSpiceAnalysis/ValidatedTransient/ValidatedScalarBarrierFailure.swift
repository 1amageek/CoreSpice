enum ValidatedScalarBarrierFailure: Error, Sendable, Equatable {
    case invalidCoefficients
    case proposalNotCertified
}
