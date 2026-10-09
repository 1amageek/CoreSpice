import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceIO
import Foundation
import Testing

@Suite("Owned source to native CPU execution", .timeLimit(.minutes(1)))
struct PreparedNativeExecutionTests {
    private let numerical = TransientExecutionLimits(maximumAcceptedSteps: 5000, maximumSolveAttempts: 10000,
        maximumNewtonIterations: 50000, maximumSavedScalars: 50000, maximumMatrixDimension: 32,
        maximumWorkUnits: 100000000, maximumBreakpoints: 1000)
    private func capture(_ text: String, key: String, resources: SourceBoundaryTestResources) throws -> SPICECheckedSource {
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: key, reference: try ArtifactReference(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        return try .admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 64)
    }
    private struct Provider: SPICEExactSourceProviding {
        let sources: [SPICECheckedSource]
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            guard let source = sources.first(where: { $0.binding == binding }) else { throw SPICEExactSourceError.undeclaredSource(binding.key) }
            return source
        }
    }
    private func input(_ text: String, key: String = "root", resources: SourceBoundaryTestResources = .init(),
        extras: [SPICECheckedSource] = [], routes: [SPICESourceCatalogRoute] = [],
        supply: [SPICESupplyBinding] = [], policy: SPICEOperatingConditionPolicy = .recordActual,
        index: Int? = nil) async throws -> PreparedSPICESimulation {
        let root = try capture(text, key: key, resources: resources)
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "native-test-v1", configuration: configuration,
            resources: resources, maximumPageByteCount: 64)
        return try await SPICESimulationPreparer().prepare(.init(root: root, environment: environment,
            catalog: [root.binding] + extras.map(\.binding), routes: routes,
            provider: Provider(sources: extras), configuration: configuration, analysisIndex: index,
            supplyBindings: supply, operatingPolicy: policy,
            limits: .init(maximumElements: 512, maximumTransformBytes: 8 * 1024 * 1024,
                maximumSweepPoints: 100, maximumPageByteCount: 64, numerical: numerical)), resources: resources)
    }
    private func native(_ input: PreparedSPICESimulation) throws -> PreparedNativeSPICESimulation {
        try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: 100,
            maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024))
    }
    private func voltage(_ output: SPICENativeSimulationOutput, _ node: String, _ point: Int) throws -> Double {
        let index = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(\(node.lowercased()))" })
        return try #require(output.waveform.realValue(variable: index, point: point))
    }
    @Test func actualOperatingPointAndIndependentConcurrentRuns() async throws {
        let prepared = try native(await input("divider\nVDD in 0 2\nR1 in out 1k\nR2 out 0 1k\n.op\n.end\n"))
        async let first = SPICENativeSimulation().execute(prepared, cancellation: .init())
        async let second = SPICENativeSimulation().execute(prepared, cancellation: .init())
        let (a,b) = try await (first,second)
        #expect(abs(try voltage(a,"out",0) - 1) < 1e-8)
        #expect(try voltage(a,"out",0) == voltage(b,"out",0))
        #expect(a.executedModels.count == 3 && a.statistics.newtonIterations > 0)
        #expect(a.sourceInputIdentity == prepared.input.sourceInputIdentity)
    }
    @Test func uicAndInitialVoltageChangeActualWaveform() async throws {
        let common = "charge\nR1 out 0 1k\nC1 out 0 1u\n"
        let charged = try native(await input(common + ".ic V(out)=2\n.tran 10u 100u UIC\n.end\n"))
        let zero = try native(await input(common + ".ic V(out)=0\n.tran 10u 100u UIC\n.end\n"))
        let a = try await SPICENativeSimulation().execute(charged, cancellation: .init())
        let b = try await SPICENativeSimulation().execute(zero, cancellation: .init())
        #expect(try voltage(a,"out",0) == 2)
        #expect(try voltage(b,"out",0) == 0)
        #expect(try voltage(a,"out",a.waveform.pointCount-1) > 1.7)
        #expect(charged.configurationIdentity != zero.configurationIdentity)
        guard case .transient(let effective) = charged.input.configuration.analysis else { Issue.record("Missing transient"); return }
        #expect(a.waveform.sweepValues.last == effective.stopTime)
    }
    @Test func nodesetActuallySeedsDCAndUnsupportedAssignmentsRefuse() async throws {
        let a = try await input("guess\nI1 out 0 -2m\nR1 out 0 1k\n.nodeset V(out)=2\n.op\n.end\n")
        #expect(a.nodeSets.bindings.count == 1)
        let out = try await SPICENativeSimulation().execute(native(a), cancellation: .init())
        #expect(abs(try voltage(out,"out",0)-2) < 1e-8)
        #expect(out.statistics.newtonIterations > 0)
        let unseeded = try await SPICENativeSimulation().execute(native(await input("guess\nI1 out 0 -2m\nR1 out 0 1k\n.op\n.end\n")), cancellation: .init())
        #expect(out.statistics.newtonIterations < unseeded.statistics.newtonIterations)
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await input("bad\nR1 out 0 1k\n.ic V(out)=1\n.op\n.end\n")
        }
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await input("bad\nR1 out 0 1k\n.nodeset V(missing)=1\n.op\n.end\n")
        }
    }
    @Test func supplyAndStimulusSweepsAreDistinctAndExactPolicyRejectsDrift() async throws {
        let deck = "sweep\nVDD supply 0 2\nVIN in 0 0\nR1 supply out 1k\nR2 out in 1k\n.dc VIN 0 2 1\n.temp 27\n.end\n"
        let binding = SPICESupplyBinding(sourceName: "vdd", positiveNode: .init(id: 1), negativeNode: .ground)
        let input = try await input(deck, supply:[binding], policy:.requireExactReference(temperatureCelsius:27,supplyVoltage:2))
        guard case .dc(_, let values, let supply) = input.configuration.analysis else { Issue.record("Missing DC"); return }
        #expect(values == [0,1,2] && !supply)
        #expect(input.configuration.prescribedSupplies == [[2]])
        let output = try await SPICENativeSimulation().execute(native(input), cancellation: .init())
        #expect(output.waveform.pointCount == 3)
        #expect(abs(try voltage(output,"out",2)-2) < 1e-8)
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await self.input(deck.replacingOccurrences(of:"R1 supply out 1k",with:"R1 supply out 1k temp=40"),
                supply:[binding],policy:.requireExactReference(temperatureCelsius:27,supplyVoltage:2))
        }
        let supplyDeck = deck.replacingOccurrences(of: ".dc VIN", with: ".dc VDD")
        let actual = try await self.input(supplyDeck, supply:[binding])
        guard case .dc(_, _, let isSupply) = actual.configuration.analysis else { Issue.record("Missing supply DC"); return }
        #expect(isSupply && actual.configuration.prescribedSupplies == [[0,1,2]])
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await self.input(supplyDeck, supply:[binding], policy:.requireExactReference(temperatureCelsius:27,supplyVoltage:2))
        }
    }
    @Test func actualIncludeSectionGraphAndRelocationIdentity() async throws {
        let resources = SourceBoundaryTestResources()
        let library = try capture("library\n.lib tt\n.model metal R r=1k tnom=35\n.endl\n.lib ff\n.model wrong R r=2k\n.endl\n", key:"lib", resources:resources)
        let deck = "owned\n.lib 'metal.lib' tt\nV1 out 0 1\nR1 out 0 metal\n.op\n.end\n"
        let routes = [SPICESourceCatalogRoute(parentKey:"root",childKey:"lib",literalRoute:"metal.lib",kind:.externalLibrary,selectedSection:"tt")]
        let prepared = try await input(deck, resources:resources, extras:[library],routes:routes)
        #expect(prepared.netlist.models.count == 1)
        #expect(prepared.sourceOccurrences.count == 2)
        #expect(prepared.sourceOccurrences[0].selectedSection == nil)
        #expect(prepared.sourceOccurrences[1].selectedSection == "tt")
        #expect(prepared.sourceOccurrences[1].source.binding == library.binding)
        let edge = try #require(prepared.netlist.dependencyEvents.first)
        #expect(edge.selectedSection == "tt" && edge.parentOccurrenceID == .init(0))
        #expect(edge.statementByteOffset != nil && edge.preprocessingIdentity != nil)
        let output = try await SPICENativeSimulation().execute(native(prepared), cancellation:.init())
        let receipt = try #require(output.executedModels.first { $0.instanceName.lowercased() == "r1" })
        #expect(receipt.model?.name.lowercased() == "metal" && receipt.model?.declarationID != nil)
        let modelConditions = try #require(prepared.configuration.instanceOperatingConditions.first { $0.modelName?.lowercased() == "metal" })
        #expect(modelConditions.nominalTemperatureCelsius == 35 && modelConditions.temperatureCelsius == 27)
        #expect(modelConditions.nominalTemperatureOrigin == "model-source")
        let relocatedLibrary = try capture(String(decoding:library.bytes,as:UTF8.self),key:"moved-lib",resources:resources)
        let relocated = try await input(deck,key:"moved-root",resources:resources,extras:[relocatedLibrary],
            routes:[.init(parentKey:"moved-root",childKey:"moved-lib",literalRoute:"metal.lib",kind:.externalLibrary,selectedSection:"tt")])
        #expect(prepared.sourceInputIdentity == relocated.sourceInputIdentity)
        #expect(try native(prepared).configurationIdentity == native(relocated).configurationIdentity)
        await #expect(throws: SPICESimulationPreparationError.self) { _ = try await input(deck) }
    }
    @Test func optionDefaultsIdentityCapacityCancellationAndUnsupportedPhysics() async throws {
        let deck = "conditions\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n"
        let retainedResources = SourceBoundaryTestResources()
        var first: PreparedSPICESimulation? = try await input(deck, resources: retainedResources)
        var lastCopy = first
        first = nil
        #expect(retainedResources.used(.liveOwnedBytes) > 0)
        withExtendedLifetime(lastCopy) {}
        lastCopy = nil
        #expect(retainedResources.used(.liveOwnedBytes) == 0)
        let refusedResources = SourceBoundaryTestResources(liveLimit: 1000)
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await input(deck, resources: refusedResources)
        }
        #expect(refusedResources.used(.liveOwnedBytes) == 0)
        let base = try await input(deck)
        let sourceTemp = try await input(deck.replacingOccurrences(of:".op",with:".temp 40\n.options tnom=20\n.op"))
        #expect(base.configuration.temperatureOrigin == "parser-default-v1")
        #expect(sourceTemp.configuration.temperatureOrigin == "source")
        #expect(sourceTemp.configuration.temperatureCelsius == 40 && sourceTemp.configuration.nominalTemperatureCelsius == 20)
        #expect(base.configuration.identity != sourceTemp.configuration.identity)
        #expect(throws: SPICENativePreparationError.self) {
            _ = try SPICENativeSimulation().prepare(base, limits:.init(maximumDeviceCount:1,maximumMatrixDimension:1,maximumAllocationBytes:1))
        }
        let cancellation = CancellationToken(); cancellation.cancel()
        await #expect(throws: SPICENativeExecutionError.self) {
            _ = try await SPICENativeSimulation().execute(native(base),cancellation:cancellation)
        }
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await input("unsupported\n.model n NMOS level=1\nM1 d g 0 0 n\n.op\n.end\n")
        }
        await #expect(throws: SPICESimulationPreparationError.self) {
            _ = try await input("expression\nR1 out 0 {1+2}\n.op\n.end\n")
        }
    }
}
