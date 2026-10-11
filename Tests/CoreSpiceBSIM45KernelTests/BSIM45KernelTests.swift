import CoreSpiceCompactModels
import CoreSpiceMOSContracts
import Testing

@Suite("BSIM4 4.5 synchronized owner", .timeLimit(.minutes(1)))
struct BSIM45KernelTests {
    private func parameter(_ name: String, _ value: Double, role: MOSParameterRole = .model) throws -> BSIM45Parameter {
        let definition = try MOSModelSchema(release: .bsim4_4_5).parameter(named: name, role: role)
        guard case .native(let id) = definition.authority else { throw BSIM45Error.invalidSchema }
        return .init(id: id, kind: definition.kind, value: value)
    }
    private func configuration(noise: Bool = true, nqs: Bool = false) throws -> BSIM45Configuration {
        try .init(polarity: .nmos, noiseRequested: noise, maximumStressIterations: 8,
            modelParameters: [parameter("vth0", 0.7), parameter("toxe", 1e-8), parameter("u0", 0.05),
                parameter("tnoimod", 1), parameter("fnoimod", 0), parameter("kf", 1e-25),
                parameter("trnqsmod", nqs ? 1 : 0), parameter("acnqsmod", nqs ? 1 : 0)],
            instanceParameters: [parameter("l", 1e-6, role: .instance), parameter("w", 1e-5, role: .instance)])
    }
    private func bias(_ owner: BSIM45Evaluator) -> SIMD16<Double> {
        var value = SIMD16<Double>.zero; value[1] = 1; value[2] = 1.2; value[4] = -0.1
        let t = owner.topology
        for (node, port) in [(t.drainPrime, 1), (t.sourcePrime, 3), (t.gatePrime, 2), (t.gateMid, 2),
            (t.bodyPrime, 4), (t.drainBody, 4), (t.sourceBody, 4)] { value[node] = value[port] }
        value[0] = 0; return value
    }
    @Test func staticACAndNoiseUseExactReleaseAndFixedValues() throws {
        let owner = try BSIM45Evaluator(configuration: configuration())
        let b = bias(owner), dc = try owner.evaluate(bias: b, analysis: .dc)
        // Cancellation is bounded relative to the actual summed magnitudes,
        // using the independently qualified C conservation contract.
        let currentMagnitude = (0..<13).reduce(0) { $0 + abs(dc.residual[$1]) }
        let chargeMagnitude = (0..<13).reduce(0) { $0 + abs(dc.charge[$1]) }
        // Each reconstructed row is G*v-rhs. Series-node cancellation can
        // dominate the terminal current; bound those 13 products and additions.
        let productMagnitude = (0..<13).reduce(0.0) { total, row in
            total + (0..<13).reduce(0.0) { $0 + abs(dc.realJacobian[row * 16 + $1] * b[$1]) }
        }
        let gamma = 27 * Double.ulpOfOne / (1 - 27 * Double.ulpOfOne)
        #expect(abs(dc.residual.sum()) <= 1e-16 + 2e-12 * currentMagnitude + gamma * productMagnitude)
        #expect(abs(dc.charge.sum()) <= 1e-28 + 2e-12 * chargeMagnitude)
        #expect(dc.residual[owner.topology.drainPrime] > 0)
        let ac = try owner.evaluate(bias: b, analysis: .ac(angularFrequency: 1e9))
        for r in 0..<13 { for c in 0..<13 { #expect(ac.realJacobian[r * 16 + c] == dc.realJacobian[r * 16 + c]) } }
        var gains = SIMD16<Double>.zero; gains[owner.topology.drainPrime] = 1
        let noise = try owner.noiseSpectrum(bias: b, frequency: 1e3, gainReal: gains, gainImaginary: .zero)
        #expect(noise.outputSpectralDensities[13] > 0)
        #expect((0..<13).reduce(0) { $0 + noise.outputSpectralDensities[$1] } == noise.outputSpectralDensities[13])
        #expect(noise.outputSpectralDensities[14] == 0 && noise.outputSpectralDensities[15] == 0)
        #expect(BSIM45Evaluator.adaptationIdentity.contains("noise-frequency-scaling-v1"))
        #expect(BSIM45Evaluator.adaptationIdentity.contains("source-velocity-chain-v1"))
    }
    @Test func everyTrialHasOwnerIdentityAndGeneration() throws {
        for nqs in [false, true] {
            let first = try BSIM45Evaluator(configuration: configuration(nqs: nqs))
            let second = try BSIM45Evaluator(configuration: configuration(nqs: nqs))
            let b = bias(first)
            try first.initializeHistory(at: b); try second.initializeHistory(at: b)
            let history = try first.acceptedStates()
            for method in [BSIM45Analysis.backwardEuler(timeStep: 1e-10), .trapezoidal(timeStep: 1e-10)] {
                let a = try first.evaluate(bias: b, analysis: method, deficitCoordinate: nqs ? 0.001 : 0)
                let token = try #require(a.token)
                #expect(throws: BSIM45Error.invalidHistory) { try second.commit(token: token) }
                #expect(try first.acceptedStates() == history)
                try first.reject(token: token)
                #expect(throws: BSIM45Error.invalidHistory) { try first.commit(token: token) }
                let fresh = try #require(try first.evaluate(bias: b, analysis: method).token)
                try first.commit(token: fresh)
                #expect(throws: BSIM45Error.invalidHistory) { try first.commit(token: fresh) }
                try first.initializeHistory(at: b)
            }
            let token = try #require(try first.evaluate(bias: b, analysis: .backwardEuler(timeStep: 1e-10)).token)
            var invalid = b; invalid[15] = 1
            #expect(throws: BSIM45Error.invalidParameter) { try first.evaluate(bias: invalid, analysis: .dc) }
            #expect(throws: BSIM45Error.invalidHistory) { try first.commit(token: token) }
            #expect(try first.acceptedStates() == history)
        }
    }
    @Test func concurrentOperationsPreserveAcceptedHistory() async throws {
        let owner = try BSIM45Evaluator(configuration: configuration(nqs: true))
        let b = bias(owner); try owner.initializeHistory(at: b)
        let original = try owner.acceptedStates()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<48 {
                group.addTask {
                    for _ in 0..<8 {
                        if index % 3 == 0 { _ = try owner.evaluate(bias: b, analysis: .dc) }
                        else if index % 3 == 1 { _ = try owner.evaluate(bias: b, analysis: .ac(angularFrequency: 1e9)) }
                        else {
                            var gain = SIMD16<Double>.zero; gain[owner.topology.drainPrime] = 1
                            _ = try owner.noiseSpectrum(bias: b, frequency: 1e3, gainReal: gain, gainImaginary: .zero)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try owner.acceptedStates() == original)
    }
    @Test func releasedOwnerTokenCannotAuthorizeANewAllocation() throws {
        func retired() throws -> BSIM45TrialToken {
            let owner = try BSIM45Evaluator(configuration: configuration())
            let b = bias(owner); try owner.initializeHistory(at: b)
            return try #require(try owner.evaluate(bias: b, analysis: .backwardEuler(timeStep: 1e-10)).token)
        }
        let token = try retired()
        let next = try BSIM45Evaluator(configuration: configuration())
        try next.initializeHistory(at: bias(next))
        #expect(throws: BSIM45Error.invalidHistory) { try next.commit(token: token) }
    }

    @Test func workScratchAndCancellationAreAdmittedBeforePublication() throws {
        let config = try configuration()
        for (temporary, work, failure) in [(UInt64(1), UInt64(10000), MOSPreparationFailure.capacityExceeded),
            (UInt64(1000000), UInt64(1), .workLimitExceeded)] {
            let limits = try MOSPreparationLimits(maximumRetainedBytes: 1000000,
                maximumTemporaryBytes: temporary, maximumDiagnosticBytes: 1000000, maximumWorkUnits: work)
            #expect(throws: failure) {
                try BSIM45Evaluator(configuration: config, preparationLimits: limits, preparationControl: nil)
            }
        }
        let limits = try MOSPreparationLimits(maximumRetainedBytes: 1000000,
            maximumTemporaryBytes: 1000000, maximumDiagnosticBytes: 1000000, maximumWorkUnits: 10000)
        for count in [0, 5, 20] {
            #expect(throws: MOSPreparationFailure.cancelled) {
                try BSIM45Evaluator(configuration: config, preparationLimits: limits,
                    preparationControl: BSIM45TestControl(cancelAfter: count))
            }
        }
    }

    @Test func failedPreparationRetainsOriginalDiagnostics() throws {
        do {
            _ = try BSIM45Evaluator(configuration: .init(polarity: .nmos, noiseRequested: false,
                maximumStressIterations: 8, modelParameters: [parameter("toxe", -1)]))
            Issue.record("Invalid oxide admitted")
        } catch let failure as BSIM45PreparationFailure {
            #expect(failure.reason == .kernelRejected)
            #expect(failure.diagnostics.contains { $0.code == 2 && $0.sourceSite > 0 && $0.text.contains("Toxe") })
        }
    }

    @Test func typedAdmissionAndBudgetsRefuseInvalidOwners() throws {
        let config = try configuration()
        let low = try MOSPreparationLimits(maximumRetainedBytes: BSIM45Evaluator.ownerAllocationBytes - 1,
            maximumTemporaryBytes: 1_000_000, maximumDiagnosticBytes: 1_000_000, maximumWorkUnits: 10_000)
        #expect(throws: MOSPreparationFailure.capacityExceeded) {
            try BSIM45Evaluator(configuration: config, preparationLimits: low, preparationControl: nil)
        }
        let duplicate = try parameter("l", 1e-6, role: .instance)
        #expect(throws: BSIM45Error.invalidSchema) {
            try BSIM45Evaluator(configuration: .init(polarity: .nmos, noiseRequested: false, maximumStressIterations: 8,
                instanceParameters: [duplicate, duplicate]))
        }
        #expect(throws: BSIM45Error.invalidSchema) {
            try BSIM45Evaluator(configuration: .init(polarity: .nmos, noiseRequested: false, maximumStressIterations: 8,
                modelParameters: [duplicate]))
        }
        #expect(throws: BSIM45Error.unsupportedVersion) {
            try BSIM45Evaluator(configuration: .init(polarity: .nmos, version: "4.8.3", noiseRequested: false, maximumStressIterations: 8))
        }
        let owner = try BSIM45Evaluator(configuration: configuration(noise: false))
        #expect(throws: BSIM45Error.noiseNotPrepared) {
            try owner.noiseSpectrum(bias: bias(owner), frequency: 1, gainReal: .zero, gainImaginary: .zero)
        }
    }
}
