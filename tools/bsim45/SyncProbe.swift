import CoreSpiceCompactModels
#if canImport(WASILibc)
import WASILibc
#else
import Darwin
#endif

func run() throws {
    let concrete = try BSIM45Evaluator(configuration: .init(polarity: .nmos, noiseRequested: true, maximumStressIterations: 8))
    let owner: any BSIM45Evaluating = concrete
    var bias = SIMD16<Double>.zero; bias[1] = 1; bias[2] = 1.2
    let topology = owner.topology
    for (node, port) in [(topology.drainPrime, 1), (topology.sourcePrime, 3)] { bias[node] = bias[port] }
    try owner.initializeHistory(at: bias)
    let before = try owner.acceptedStates()
    let dc = try owner.evaluate(bias: bias, analysis: .dc, deficitCoordinate: 0, minimumJunctionConductance: 1e-12)
    precondition(dc.residual.sum().isFinite)
    let trial = try owner.evaluate(bias: bias, analysis: .backwardEuler(timeStep: 1e-10), deficitCoordinate: 0, minimumJunctionConductance: 1e-12)
    guard let token = trial.token else { fatalError("Missing trial") }
    try owner.reject(token: token)
    let after = try owner.acceptedStates(); precondition(after == before)
    var gain = SIMD16<Double>.zero; gain[topology.drainPrime] = 1
    let noise = try owner.noiseSpectrum(bias: bias, frequency: 1e3, gainReal: gain, gainImaginary: .zero, minimumJunctionConductance: 1e-12)
    precondition(noise.outputSpectralDensities[13] > 0)
    do { try owner.commit(token: token); fatalError("Stale token admitted") }
    catch BSIM45Error.invalidHistory {}
    fflush(nil)
    print("BSIM45 same Mutex owner: existential calls, rejection, history and noise passed"); fflush(nil)
}
@main struct Probe {
    static func main() {
        do { try run() } catch { fatalError("BSIM45 synchronous owner failed") }
    }
}
