/// Fixed owned results with zero padding; history has exactly 29 active slots.
public struct BSIM45Evaluation: Sendable {
    public let residual: SIMD16<Double>
    public let rhs: SIMD16<Double>
    public let charge: SIMD16<Double>
    public let realJacobian: BSIM45Matrix
    public let imaginaryJacobian: BSIM45Matrix
    public let states: SIMD32<Double>
    public let token: BSIM45TrialToken?
}
