public protocol BSIM45Evaluating: Sendable {
    var topology: BSIM45Topology { get }
    var diagnostics: [BSIM45Diagnostic] { get }
    func evaluate(bias: SIMD16<Double>, analysis: BSIM45Analysis, deficitCoordinate: Double,
                  minimumJunctionConductance: Double) throws -> BSIM45Evaluation
    func initializeHistory(at bias: SIMD16<Double>) throws
    func commit(token: BSIM45TrialToken) throws
    func reject(token: BSIM45TrialToken) throws
    func acceptedStates() throws -> SIMD32<Double>
    func noiseSpectrum(bias: SIMD16<Double>, frequency: Double, gainReal: SIMD16<Double>,
                       gainImaginary: SIMD16<Double>, minimumJunctionConductance: Double) throws -> BSIM45NoiseSpectrum
}
