public protocol BSIM4Evaluating: Sendable {
    var topology: BSIM4Topology { get }
    var diagnostics: [BSIM4Diagnostic] { get }
    func evaluate(bias: SIMD16<Double>, analysis: BSIM4Analysis,
                  minimumJunctionConductance: Double) throws -> BSIM4Evaluation
    func noiseSpectrum(bias: SIMD16<Double>, frequency: Double,
                       gainReal: SIMD16<Double>, gainImaginary: SIMD16<Double>,
                       minimumJunctionConductance: Double) throws -> BSIM4NoiseSpectrum
    func initializeHistory(at bias: SIMD16<Double>) throws
    func commit(token: UInt64) throws
    func acceptedStates() throws -> SIMD32<Double>
}
