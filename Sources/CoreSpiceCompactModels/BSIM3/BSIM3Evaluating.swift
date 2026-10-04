/// Safe synchronous compact-model contract; all outputs have independent lifetime.
public protocol BSIM3Evaluating: Sendable {
    var topology: BSIM3Topology { get }
    var diagnostics: [BSIM3Diagnostic] { get }
    func evaluate(bias: SIMD8<Double>, analysis: BSIM3Analysis, minimumJunctionConductance: Double) throws -> BSIM3Evaluation
    func noiseSpectrum(bias: SIMD8<Double>, frequency: Double, minimumJunctionConductance: Double) throws -> BSIM3NoiseSpectrum
    func initializeHistory(at bias: SIMD8<Double>) throws
    func commit(token: UInt64) throws
    func acceptedStates() -> SIMD32<Double>
}
