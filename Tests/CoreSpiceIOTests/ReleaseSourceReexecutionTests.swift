import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import Synchronization
import Testing

@Suite("Release source run discovery storage", .timeLimit(.minutes(1)))
struct ReleaseSourceReexecutionTests {
    private final class MeasuredResources: SPICESourceResourceAccounting {
        let original: SPICESimulationResources
        private let largestTemporary = Mutex<UInt64>(0)
        init() throws {
            original = try .init(maximumLiveBytes: 4 * 1024 * 1024 * 1024,
                maximumTemporaryBytes: 1024 * 1024 * 1024,
                maximumWorkUnits: 100_000_000, maximumHashedBytes: 1024 * 1024)
        }
        var maximumTemporaryRequest: UInt64 { largestTemporary.withLock { $0 } }
        func checkCancellation() throws { try original.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try original.charge(kind, units: units) }
        func chargeHashedBytes(_ count: UInt64) throws { try original.chargeHashedBytes(count) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            if kind == .temporaryBytes { largestTemporary.withLock { $0 = max($0, byteCount) } }
            return try original.reserveStorage(kind: kind, byteCount: byteCount)
        }
    }
    private struct EmptyProvider: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }

    @Test(arguments: [false, true])
    func discoveryUsesActualTemperatureStorageWithLargeResolutionPolicy(hasFamily: Bool) async throws {
        let resources = try MeasuredResources()
        // Keep another actual invocation lease alive, as preprocessing does in the production CLI.
        let otherTemporary = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 1)
        do {
            let text = "Discovery\nV1 out 0 1\nR1 out 0 1k\n" + (hasFamily ? ".temp 27 77\n" : "") + ".op\n.end\n"
            let bytes = Array(text.utf8)
            let digest = try SHA256ContentDigester().digest(using: .sha256,
                limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                    (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
                }
            let binding = SPICEExactSourceBinding(key: "root", reference: try .init(digest: digest.digest,
                byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
            let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 64)
            let parser = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "release-discovery-v1",
                configuration: parser, resources: resources, maximumPageByteCount: 64)
            let resolution = try MOSResolutionLimits(maximumRetainedBytes: 512 * 1024 * 1024,
                maximumDiagnosticBytes: 4096, maximumScopeDepth: 32, maximumSymbols: 256, maximumScopes: 32,
                maximumInvocations: 64, maximumInvocationBindings: 512, maximumDeclarations: 128,
                maximumPrograms: 256, maximumBindings: 256, maximumFunctions: 32, maximumFunctionDepth: 32,
                maximumExpressionNodes: 256, maximumExpressionDepth: 128, maximumCandidates: 128,
                maximumCacheEntries: 256, maximumEvaluationSteps: 1_000_000)
            let numerical = TransientExecutionLimits(maximumAcceptedSteps: 100, maximumSolveAttempts: 100,
                maximumNewtonIterations: 1000, maximumSavedScalars: 1000, maximumMatrixDimension: 32,
                maximumWorkUnits: 1_000_000, maximumBreakpoints: 100)
            let request = SPICESimulationPreparationRequest(root: root, environment: environment, catalog: [binding],
                routes: [], provider: EmptyProvider(), configuration: parser, operatingPolicy: .recordActual,
                limits: .init(maximumElements: 128, maximumTransformBytes: 1024 * 1024,
                    maximumSweepPoints: 20, maximumPageByteCount: 64, numerical: numerical),
                profile: .coreStrictV1, seed: 42, resolutionLimits: resolution)
            let family = try await SPICESimulationPreparer().prepareRuns(request, resources: resources)
            #expect(family.selections.count == (hasFamily ? 2 : 1))
            #expect(family.selections.map { $0.temperatureSelection?.celsius } == (hasFamily ? [27, 77] : [nil]))
            #expect(family.selections.allSatisfy { $0.seed == 42 })
            #expect(resources.maximumTemporaryRequest < resolution.maximumRetainedBytes)
        }
        // Discovery releases every source, environment, parse and selection lease at its owner boundary.
        let allLive = try resources.original.reserveStorage(kind: .liveOwnedBytes, byteCount: 4 * 1024 * 1024 * 1024)
        let remainingTemporary = try resources.original.reserveStorage(kind: .temporaryBytes, byteCount: 1024 * 1024 * 1024 - 1)
        withExtendedLifetime((otherTemporary, allLive, remainingTemporary)) {}
    }
}
