import AllocationProbe
import CoreSpiceCompactModels
import CoreSpiceMOSContracts
import Darwin

@main struct BenchmarkProbe {
    static func main() throws {
        let schema = MOSModelSchema(release: .bsim4_4_5)
        func parameter(_ name: String, _ value: Double, role: MOSParameterRole = .model) throws -> BSIM45Parameter {
            let definition = try schema.parameter(named: name, role: role)
            guard case .native(let id) = definition.authority else { throw BSIM45Error.invalidSchema }
            return .init(id: id, kind: definition.kind, value: value)
        }
        let configuration = try BSIM45Configuration(polarity: .nmos, noiseRequested: true, maximumStressIterations: 8,
            modelParameters: [parameter("vth0", 0.7), parameter("toxe", 1e-8), parameter("u0", 0.05),
                parameter("trnqsmod", 1), parameter("acnqsmod", 1)],
            instanceParameters: [parameter("l", 1e-6, role: .instance), parameter("w", 1e-5, role: .instance)])
        let bytes = Int(BSIM45Evaluator.ownerAllocationBytes)
        cs_probe_begin(bytes)
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let owner = try BSIM45Evaluator(configuration: configuration)
        let preparationNanoseconds = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start
        let preparationCounts = cs_probe_end()
        precondition(preparationCounts.exactOwnerCallocs == 1)
        var bias = SIMD16<Double>.zero; bias[1] = 1; bias[2] = 1.2
        let t = owner.topology
        for (node, port) in [(t.drainPrime, 1), (t.sourcePrime, 3), (t.gatePrime, 2), (t.gateMid, 2),
            (t.bodyPrime, 4), (t.drainBody, 4), (t.sourceBody, 4)] { bias[node] = bias[port] }
        var gain = SIMD16<Double>.zero; gain[t.drainPrime] = 1
        try owner.initializeHistory(at: bias)
        for _ in 0..<16 {
            _ = try owner.evaluate(bias: bias, analysis: .dc)
            _ = try owner.evaluate(bias: bias, analysis: .ac(angularFrequency: 1e9))
            let result = try owner.evaluate(bias: bias, analysis: .backwardEuler(timeStep: 1e-10))
            guard let token = result.token else { fatalError("Missing trial") }; try owner.commit(token: token)
            _ = try owner.noiseSpectrum(bias: bias, frequency: 1e3, gainReal: gain, gainImaginary: .zero)
        }
        // Positive control proves that optimized Swift buffer allocation is observed.
        cs_probe_begin(bytes)
        let control = [UInt8](repeating: 7, count: 4096)
        control.withUnsafeBufferPointer { cs_probe_consume($0.baseAddress!, $0.count) }
        let controlCounts = cs_probe_end(); precondition(controlCounts.allocationEntryCalls > 0)
        let iterations = 10000
        var checksum = 0.0
        for phase in 0..<4 {
            cs_probe_begin(bytes)
            let phaseStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            for _ in 0..<iterations {
                switch phase {
                case 0: checksum += try owner.evaluate(bias: bias, analysis: .dc).residual[1]
                case 1: checksum += try owner.evaluate(bias: bias, analysis: .ac(angularFrequency: 1e9)).realJacobian[17]
                case 2:
                    let result = try owner.evaluate(bias: bias, analysis: .backwardEuler(timeStep: 1e-10))
                    guard let token = result.token else { fatalError("Missing trial") }
                    try owner.commit(token: token); checksum += result.residual[1]
                default:
                    checksum += try owner.noiseSpectrum(bias: bias, frequency: 1e3, gainReal: gain,
                        gainImaginary: .zero).outputSpectralDensities[13]
                }
            }
            let nanoseconds = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - phaseStart
            let counts = cs_probe_end()
            precondition(counts.allocationEntryCalls == 0 && counts.exactOwnerCallocs == 0)
            print("{\"phase\":\(phase),\"iterations\":\(iterations),\"nanoseconds\":\(nanoseconds),\"allocationEntryCalls\":\(counts.allocationEntryCalls),\"coldSetupCount\":\(counts.exactOwnerCallocs)}")
        }
        precondition(checksum.isFinite)
        print("{\"ownerBytes\":\(bytes),\"swiftStoredPayloadBytes\":\(BSIM45Evaluator.storedPayloadBytes),\"diagnosticBytes\":\(owner.diagnosticStorageBytes),\"preparationTemporaryBytes\":\(owner.preparationTemporaryBytes),\"preparationNanoseconds\":\(preparationNanoseconds),\"preparationAllocationEntryCalls\":\(preparationCounts.allocationEntryCalls),\"preparationColdSetups\":\(preparationCounts.exactOwnerCallocs),\"positiveControlAllocations\":\(controlCounts.allocationEntryCalls)}")
    }
}
