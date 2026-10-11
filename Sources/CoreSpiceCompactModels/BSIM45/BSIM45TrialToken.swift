/// Tokens retain only this immutable marker, never a C pointer or evaluator.
final class BSIM45TrialIdentity: Sendable {}

/// Authorization for one trial of one live evaluator; construction is internal.
public struct BSIM45TrialToken: Sendable {
    let identity: BSIM45TrialIdentity
    let generation: UInt64
}
