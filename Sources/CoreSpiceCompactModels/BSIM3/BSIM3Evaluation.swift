/// Owned fixed-size nonlinear residual, exact stamps and original charge states.
public struct BSIM3Evaluation: Sendable {
    public let residual: SIMD8<Double>
    public let rhs: SIMD8<Double>
    public let charge: SIMD8<Double>
    /// Row-major 8 by 8 matrix, including ground slot zero.
    public let realJacobian: SIMD64<Double>
    public let imaginaryJacobian: SIMD64<Double>
    /// Original state slots 0...16; slots 17...31 are zero.
    public let states: SIMD32<Double>
    /// cd, gm, gds, gmbs, von, vdsat, csub, mode, in original normalized polarity.
    public let operatingPoint: SIMD8<Double>
    public let token: UInt64
}
