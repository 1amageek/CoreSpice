import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import CoreSpiceOSDIContracts
import Testing

@Suite("Prepared OSDI source transport", .timeLimit(.minutes(1)))
struct OSDIPreparedSourceTests {
    private struct NoDependencies: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }
    private func prepare(_ input: OSDIResolvedInstance, analysis: String = ".op") async throws -> PreparedSPICESimulation {
        let resources = try SPICESimulationResources(maximumLiveBytes: 64 * 1024 * 1024,
            maximumTemporaryBytes: 64 * 1024 * 1024, maximumWorkUnits: 100_000_000, maximumHashedBytes: 1024 * 1024)
        let text = "prepared OSDI\n.temp 40\n.model foreign osdi\nV1 p 0 1\nN1 p 0 foreign\n\(analysis)\n.end\n"
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "root", reference: try .init(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span,
            resources: resources, maximumPageByteCount: 64)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "osdi-source-test-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 64)
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 1000, maximumSolveAttempts: 2000,
            maximumNewtonIterations: 10000, maximumSavedScalars: 10000, maximumMatrixDimension: 32,
            maximumWorkUnits: 1_000_000, maximumBreakpoints: 100)
        return try await SPICESimulationPreparer().prepare(.init(root: root, environment: environment,
            catalog: [binding], routes: [], provider: NoDependencies(), configuration: parser,
            operatingPolicy: .recordActual,
            limits: .init(maximumElements: 128, maximumTransformBytes: 1024 * 1024,
                maximumSweepPoints: 20, maximumPageByteCount: 64, numerical: numerical),
            profile: .pinnedNgspiceNormalV1, seed: 1, resolutionLimits: OSDIFrontendTests().limits(),
            osdiInstances: ["n1": input]), resources: resources)
    }
    @Test func originalPublicSourceAPIUsesSameTypedBinding() async throws {
        let selected = try OSDIFrontendTests().input()
        let result = try await SPICEIO.parseAndLower("OSDI\n.model foreign osdi\nN1 p 0 foreign\n.end\n",
            profile: .pinnedNgspiceNormalV1, seed: 1, limits: OSDIFrontendTests().limits(), osdiInstances: ["n1": selected])
        #expect(result.circuit.instances.first?.osdi?.resolved == selected)
    }
    @Test func actualPreparedMapRetainsTypedInputsAndChangesSemanticIdentity() async throws {
        let fixture = OSDIFrontendTests()
        let first = try await prepare(fixture.input())
        let repeated = try await prepare(fixture.input())
        let changedText = try await prepare(fixture.input(text: "different"))
        let original = try fixture.input()
        let changedState = try await prepare(.init(binding: original.binding,
            instanceParameters: original.instanceParameters, previousState: [2, 1]))
        let instance = try #require(first.circuit.instances.first { $0.name == "n1" })
        #expect(instance.osdi?.resolved == original)
        #expect(first.configuration.identity == repeated.configuration.identity)
        #expect(first.sourceInputIdentity == changedText.sourceInputIdentity)
        #expect(first.configuration.identity != changedText.configuration.identity)
        #expect(first.configuration.identity != changedState.configuration.identity)
        #expect(first.circuit.evaluationEnvironment?.ambientKelvinBits == Double(313.15).bitPattern)
        #expect(first.configuration.instanceOperatingConditions.first { $0.instanceName == "n1" }?.modelName == "foreign")
    }
    @Test func preparedDynamicIntentRetainsExactBindingForNativeAdmission() async throws {
        for analysis in [".dc V1 0 1 .5", ".tran 1u 10u"] {
            let selected = try OSDIFrontendTests().input()
            let prepared = try await prepare(selected, analysis: analysis)
            let instance = try #require(prepared.circuit.instances.first { $0.name == "n1" })
            #expect(instance.osdi?.resolved == selected)
            switch prepared.configuration.analysis {
            case .dc(let sourceName, let values, _):
                #expect(analysis.hasPrefix(".dc") && sourceName.lowercased() == "v1")
                #expect(values == [0, 0.5, 1])
            case .transient(let configuration):
                #expect(analysis.hasPrefix(".tran"))
                #expect(configuration.stopTime == 10 * 1e-6)
                #expect(configuration.initialTimeStep == 1e-6)
            default:
                Issue.record("Prepared OSDI source changed the requested dynamic analysis")
            }
        }
    }
}
