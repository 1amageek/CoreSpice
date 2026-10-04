/// Fixed owned values. Matrices use stride 16 and zero padding; history preserves all 29 states.
public struct BSIM4Evaluation: Sendable {
    public let residual: SIMD16<Double>
    public let rhs: SIMD16<Double>
    public let charge: SIMD16<Double>
    public let realJacobian: BSIM4Matrix
    public let imaginaryJacobian: BSIM4Matrix
    public let states: SIMD32<Double>
    /// Original polarity-normalized id, gm, gds, gmbs, vth, vdsat, isub, mode.
    public let operatingPoint: SIMD8<Double>
    /// Original intrinsic qg, qd, qb, qs, scaled by mult_q, before overlap/junction composition.
    public let intrinsicCharges: SIMD4<Double>
    public let token: UInt64
}
