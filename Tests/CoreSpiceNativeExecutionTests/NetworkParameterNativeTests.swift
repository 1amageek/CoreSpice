import CoreSpice
@testable import CoreSpiceIO
import Testing

@Suite("Explicit fixed-bias network native composition", .timeLimit(.minutes(1)))
struct NetworkParameterNativeTests {
    private let deck = """
    Coupled ports
    V1 a 0 dc 1 ac 23
    V2 b 0 dc 2 ac 71
    R1 a 0 100
    R2 b 0 200
    R3 a b 400
    .ac lin 2 100 200
    .end
    """

    private func input() async throws -> PreparedSPICESimulation {
        let base = try await PreparedNativeExecutionTests().input(deck)
        let policy = NetworkParameterLimits(maximumPorts: 4, maximumFrequencyPoints: 4,
            maximumResultScalars: 1000, maximumTemporaryBytes: 1024 * 1024,
            residualTolerance: 1e-10, executionLimits: base.configuration.numericalLimits)
        return try SPICESimulationPreparer().reprepare(base, analysisIndex: 0,
            networkSelection: .init(ports: [try .init(voltageSourceName: "v1", referenceImpedance: 50),
                try .init(voltageSourceName: "v2", referenceImpedance: 75)], limits: policy))
    }

    @Test func completeIndependentBasisRetainsBiasAndNativePhaseIdentity() async throws {
        let input = try await input()
        let native = SPICENativeSimulation()
        let owner = try native.prepare(input, limits: .init(maximumDeviceCount: 100,
            maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024))
        let shared = try AnalysisExecutionResources(limits: input.configuration.numericalLimits)
        let output = try await native.execute(owner, cancellation: .init(), executionResources: shared)
        let result = try #require(output.networkResult)
        #expect(output.phases.map(\.analysis) == ["op", "network"])
        #expect(output.phases.map(\.completedPointCount) == [1, 2])
        #expect(result.points.map(\.frequency) == [100, 200])
        #expect(output.waveform.metadata.analysisType == .networkParameters)
        let expected = [0.0125, -0.0025, -0.0025, 0.0075]
        for point in result.points {
            for (index, value) in point.y.values.enumerated() {
                #expect(abs(value.real - expected[index]) < 1e-14)
                #expect(value.imag == 0)
            }
            guard case .defined(let z) = point.z else { Issue.record("Invertible admittance lost Z"); continue }
            #expect(abs(z.values[0].real - 600.0 / 7) < 1e-10)
            #expect(point.stability != nil)
        }
        #expect(result.operatingPoint.variables == output.operatingPoint?.variables)
        #expect(output.sourceInputIdentity == input.sourceInputIdentity)
        #expect(shared.usage.solveAttempts == output.statistics.solveAttempts)
        #expect(output.waveform.variables.map(\.name) == ["S[1,1]", "S[1,2]", "S[2,1]", "S[2,2]", "Y[1,1]", "Y[1,2]", "Y[2,1]", "Y[2,2]"])
    }

    @Test func cancellationRefusesBeforeAnyCompletedNetworkOutput() async throws {
        let input = try await input()
        let token = CancellationToken(); token.cancel()
        let owner = try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: 100,
            maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024))
        do {
            _ = try await SPICENativeSimulation().execute(owner, cancellation: token)
            Issue.record("Cancelled network published completed output")
        } catch SPICENativeExecutionError.cancelled { }
    }
    @Test func allPreparationEntriesRefuseMissingIndexNegativeLimitsAndEmptyPorts() async throws {
        let basis = try await PreparedNativeExecutionTests().input(deck)
        let original = basis.request
        for mode in 0..<3 {
            let policy = NetworkParameterLimits(maximumPorts: 4, maximumFrequencyPoints: 4,
                maximumResultScalars: mode == 1 ? -1 : 1000, maximumTemporaryBytes: 1024 * 1024,
                residualTolerance: 1e-10, executionLimits: basis.configuration.numericalLimits)
            let selection = SPICENetworkParameterSelection(ports: mode == 2 ? [] : [
                try .init(voltageSourceName: "v1", referenceImpedance: 50)], limits: policy)
            let index: Int? = mode == 0 ? nil : 0
            let request = SPICESimulationPreparationRequest(root: original.root, environment: original.environment,
                catalog: original.catalog, routes: original.routes, provider: original.provider,
                configuration: original.configuration, analysisIndex: index, supplyBindings: original.supplyBindings,
                operatingPolicy: original.operatingPolicy, limits: original.limits, profile: original.profile,
                seed: original.seed, resolutionLimits: original.resolutionLimits,
                temperaturePolicy: original.temperaturePolicy, diodeProfile: original.diodeProfile,
                osdiInstances: original.osdiInstances, parameterOverrides: original.parameterOverrides,
                sourceOverrides: original.sourceOverrides, temperatureSelection: original.temperatureSelection,
                monteCarloSeedOverride: original.monteCarloSeedOverride, captureSourceScalars: original.captureSourceScalars,
                networkSelection: selection, externalMOSPreparers: original.externalMOSPreparers)
            for entry in 0..<3 {
                do {
                    if entry == 0 { _ = try await SPICESimulationPreparer().prepare(request, resources: basis.resources) }
                    else if entry == 1 { _ = try await SPICESimulationPreparer().prepareRuns(request, resources: basis.resources) }
                    else { _ = try SPICESimulationPreparer().reprepare(basis, analysisIndex: index, networkSelection: selection) }
                    Issue.record("Invalid network selection reached a prepared owner: mode \(mode), entry \(entry)")
                } catch let error as SPICESimulationPreparationError {
                    switch error {
                    case .unsupportedCapability: #expect(mode != 1)
                    case .resource(let cause):
                        guard case NetworkParameterError.invalidConfiguration = cause else { throw cause }
                        #expect(mode == 1)
                    default: Issue.record("Unexpected network refusal: \(error)")
                    }
                }
            }
        }
    }

}
