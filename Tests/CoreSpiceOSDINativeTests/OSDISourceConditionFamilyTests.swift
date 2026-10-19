import CircuiteFoundation
import CircuiteFoundationCrypto
@testable import CoreSpice
@testable import CoreSpiceIO
import CoreSpiceOSDITestSupport
import Foundation
import Testing

@Suite("OSDI source temperature and seed family", .timeLimit(.minutes(3)))
struct OSDISourceConditionFamilyTests {
    @Test(arguments: ["bsim-p-selfheat-loaded", "cmg-n-selfheat-series-loaded", "img-n-loaded", "soi101-n-dd-hot-series-thermal"])
    func exactModelsRunEveryConditionAndMatchIndependentFreshDC(_ id: String) async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == id })
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        let temperature = try #require(point.input.devices.first).temperatureKelvin - 273.15
        let family = try await sourceFamily(fixture: fixture, point: point, gate: gate.id, gateValue: gate.value,
            temperature: temperature)
        #expect(family.selections.count == 4)
        #expect(family.selections.map(\.seed) == [17, 18, 17, 18])
        #expect(family.selections.map { $0.temperatureSelection?.celsius } == [temperature, temperature, temperature + 1, temperature + 1])
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        var invocation: AnalysisExecutionResources?
        var proofValues: [Double] = [], configurationIDs: [String] = []
        for index in family.selections.indices {
            let input = try family.prepareRun(at: index)
            if invocation == nil { invocation = try .init(limits: input.configuration.numericalLimits) }
            #expect(input.sourceInputIdentity == family.sourceInputIdentity)
            #expect(input.configuration.seed == family.selections[index].seed)
            #expect(input.lowered.evaluationProvenance.randomDraws > 0)
            #expect(input.configuration.runSelection.monteCarloIteration == index % 2)
            #expect(input.configuration.runSelection.monteCarloSeedOrigin == .sourceDirective)
            let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
                osdi: fixture.runtime(point, provider: tracked))
            let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init(),
                executionResources: try #require(invocation))
            try tracked.expectClosed()
            let sweep = try #require(output.dcSweepResult)
            try #require(sweep.results.count == 1)
            #expect(sweep.values == [gate.value])
            #expect(output.phases.map(\.analysis) == ["dc"])
            let facts = try #require(output.phases.first)
            #expect(facts.osdiPreparationRecords.count == point.input.devices.count)
            #expect(facts.equationPolicy?.rows.count == output.prepared.plan.topology.dimension)
            for device in point.input.devices {
                let receipt = try #require(facts.osdiPreparationRecords.first {
                    $0.instanceName == OSDINativeFixture.sourceName(device.id)
                }).receipt
                let expected = try #require(input.request.osdiInstances[OSDINativeFixture.sourceName(device.id)])
                #expect(receipt.resolved == expected)
                #expect(receipt.resolved.binding.artifact == fixture.references[device.library])
                #expect(receipt.effectiveTemperatureKelvin == input.configuration.temperatureCelsius + 273.15)
            }
            let proof = try #require(input.circuit.nodeNames.first { $0.value == "proof" }?.key)
            let sourceValue = try #require(input.circuit.instances.first { $0.name == "vproof" })
            guard case .real(let sampled) = sourceValue.parameters["v"] else {
                Issue.record("Random source voltage was not resolved"); return
            }
            let observed = try sweep.results[0].checkedVoltage(at: proof)
            #expect(abs(observed - sampled) < 1e-12)
            proofValues.append(observed); configurationIDs.append(output.configurationIdentity.hexadecimalValue)

            // A separate source evaluation, isolated image and direct OP solve use the same exact conditions.
            let replay = try SPICESimulationPreparer().reprepare(input)
            #expect(replay.configuration.identity == input.configuration.identity)
            #expect(replay.lowered.evaluationProvenance.seed == input.configuration.seed)
            let owner = try await NativeCircuitPreparer().prepare(ir: replay.circuit, registry: .standard(),
                operatingConditions: replay.configuration.options.operatingConditions(), limits: fixture.limits,
                numericalLimits: replay.configuration.numericalLimits, resources: replay.resources,
                osdi: fixture.runtime(point, provider: tracked))
            var guesses: [Node: Double] = [:]
            for guess in replay.nodeSets.bindings { guesses[guess.node] = guess.voltage }
            let independent = try await DCAnalysis(config: replay.configuration.options.convergence, nodeInitialGuess: guesses)
                .run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(independent.result.variableMap == sweep.results[0].variableMap)
            #expect(independent.result.variables.map(\.bitPattern) == sweep.results[0].variables.map(\.bitPattern))
            #expect(independent.result.variableLowComponents?.map(\.bitPattern) == sweep.results[0].variableLowComponents?.map(\.bitPattern))
            try tracked.expectClosed()
        }
        #expect(Set(configurationIDs).count == 4)
        #expect(proofValues[0] != proofValues[1])
        #expect(abs((proofValues[2] - proofValues[0]) - 1e-5) < 1e-12)
        #expect(abs((proofValues[3] - proofValues[1]) - 1e-5) < 1e-12)
        #expect(tracked.count == 8 * point.input.devices.count)
        #expect(try #require(invocation).usage.solveAttempts > 0)
    }

    private func sourceFamily(fixture: OSDINativeFixture, point: OSDIDCManifest.Case,
                              gate: String, gateValue: Double, temperature: Double) async throws -> PreparedSPICESimulationRuns {
        let baseline = try await fixture.input(point)
        let text = String(decoding: try #require(baseline.sources.first).bytes, as: UTF8.self)
            .replacingOccurrences(of: ".op\n", with: """
            .temp \(temperature) \(temperature + 1)
            .param family_bias={0.1+0.01*rand()+0.00001*temper}
            Vproof proof 0 {family_bias}
            Rproof proof 0 1k
            .mc 2 dc \(gate) \(gateValue) \(gateValue) 1e-5 seed=17

            """)
        let bytes = Array(text.utf8), basis = baseline.request
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
            }
        let binding = SPICEExactSourceBinding(key: "root", reference: try .init(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: baseline.resources,
            maximumPageByteCount: 65536)
        let request = SPICESimulationPreparationRequest(root: root, environment: basis.environment,
            catalog: [binding], routes: [], provider: basis.provider, configuration: basis.configuration,
            operatingPolicy: .recordActual,
            limits: .init(maximumElements: 2048, maximumTransformBytes: 32 * 1024 * 1024,
                maximumSweepPoints: 4, maximumPageByteCount: 65536, numerical: fixture.numerical),
            profile: basis.profile, seed: basis.seed, resolutionLimits: basis.resolutionLimits,
            osdiInstances: basis.osdiInstances)
        return try await SPICESimulationPreparer().prepareRuns(request, resources: baseline.resources)
    }
}
