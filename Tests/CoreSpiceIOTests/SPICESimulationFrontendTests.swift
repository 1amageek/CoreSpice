import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import CoreSpiceMOSResolution
import Foundation
import Testing

@Suite("Prepared simulation shared frontend", .timeLimit(.minutes(1)))
struct SPICESimulationFrontendTests {
    private struct NoDependencies: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }
    private func resources() throws -> SPICESimulationResources {
        try .init(maximumLiveBytes: 64 * 1024 * 1024, maximumTemporaryBytes: 64 * 1024 * 1024,
                  maximumWorkUnits: 100_000_000, maximumHashedBytes: 1024 * 1024)
    }
    private func prepare(_ text: String, resources: SPICESimulationResources,
                         profile: MOSInputProfile = .coreStrictV1, seed: UInt64 = 123,
                         maximumElements: Int = 128,
                         maximumTransformBytes: UInt64 = 1024 * 1024) async throws -> PreparedSPICESimulation {
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "root", reference: try ArtifactReference(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 64)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "io-frontend-test-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 64)
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 1000, maximumSolveAttempts: 2000,
            maximumNewtonIterations: 10000, maximumSavedScalars: 10000, maximumMatrixDimension: 32,
            maximumWorkUnits: 1_000_000, maximumBreakpoints: 100)
        return try await SPICESimulationPreparer().prepare(.init(root: root, environment: environment,
            catalog: [binding], routes: [], provider: NoDependencies(), configuration: parser,
            operatingPolicy: .recordActual,
            limits: .init(maximumElements: maximumElements, maximumTransformBytes: maximumTransformBytes,
                maximumSweepPoints: 20, maximumPageByteCount: 64, numerical: numerical),
            profile: profile, seed: seed, resolutionLimits: IOTestFrontend.limits), resources: resources)
    }

    @Test func hierarchyAndResolvedMOSRetainActualSourceAndInspectionOwners() async throws {
        let text = """
        prepared scoped MOS
        .options scale={1u} reltol={0.001+rand()*0.001}
        .subckt cell d g params: len=1
        .model nch nmos level=1 kp=2e-5 vto=.7
        M1 d g 0 0 nch l={len} w=2
        .ends
        VD d 0 1
        VG g 0 1.2
        X1 d g cell len={1+rand()}
        .op
        .end
        """
        let input = try await prepare(text, resources: resources())
        #expect(input.sources.count == 1)
        #expect(input.sources[0].bytes == Data(text.utf8))
        #expect(input.lowered.graph.invocations.count == 2)
        let instance = try #require(input.circuit.instances.first { $0.name == "x1.m1" })
        guard case .resolved(let resolved) = instance.mos else { Issue.record("Missing resolved nested MOS"); return }
        #expect(resolved.instance == "x1.m1" && resolved.release == .level1)
        #expect(resolved.source.captureID == "root")
        #expect(resolved.normalizedGeometry.width == 2e-6)
        _ = try inspectResolvedMOS(resolved, from: input.lowered.snapshot, limits: IOTestFrontend.limits)
        #expect(input.configuration.instanceOperatingConditions.first { $0.instanceName == "x1.m1" }?.modelName == "nch")
        #expect(input.lowered.evaluationProvenance.seed == 123)
        #expect(input.lowered.evaluationProvenance.randomDraws == 2)
    }

    @Test func expressionSettingsICAndSelectedAnalysisUseOneSessionAndProfileIdentity() async throws {
        let text = """
        prepared expression settings
        .param t=1u
        .options reltol={0.001+rand()*0.001}
        .temp {20+rand()}
        R1 out 0 1k
        C1 out 0 1u
        .ic V(out)={1+rand()}
        .tran {t} {10*t} uic
        .end
        """
        let strict = try await prepare(text, resources: resources(), seed: 123)
        guard case .transient(let config) = strict.configuration.analysis else { Issue.record("Missing transient config"); return }
        #expect(abs(config.stopTime - 1e-5) < 1e-20)
        #expect(config.useInitialConditions && strict.initialConditions.bindings.count == 1)
        let initial = try #require(strict.initialConditions.bindings.first)
        #expect(initial.voltage >= 1 && initial.voltage <= 2)
        #expect(strict.configuration.seed == 123 && strict.lowered.evaluationProvenance.seed == 123)
        #expect(strict.lowered.evaluationProvenance.randomDraws == 3)
        let pinned = try await prepare(text, resources: resources(), profile: .pinnedNgspiceNormalV1, seed: 123)
        #expect(strict.sourceInputIdentity == pinned.sourceInputIdentity)
        #expect(strict.configuration.identity != pinned.configuration.identity)
    }

    @Test func finalPreparedCopyOwnsFrontendCapacityUntilRelease() async throws {
        let owner = try resources()
        var first: PreparedSPICESimulation? = try await prepare("retention\nR1 out 0 1k\n.op\n.end\n", resources: owner)
        var last = first; first = nil
        #expect(last?.circuit.instances.count == 1)
        do {
            _ = try owner.reserveStorage(kind: .liveOwnedBytes, byteCount: 64 * 1024 * 1024)
            Issue.record("Live prepared owner did not retain its capacity")
        } catch let error as SPICESimulationResources.ResourceError {
            guard case .storageLimit = error else { throw error }
        }
        last = nil
        let released = try owner.reserveStorage(kind: .liveOwnedBytes, byteCount: 64 * 1024 * 1024)
        #expect(released.byteCount == 64 * 1024 * 1024)
    }

    @Test func firstPreparationFitsSharedTemporaryBudgetWithoutReservingEncodingCeiling() async throws {
        let capacity: UInt64 = 64 * 1024 * 1024
        let owner = try SPICESimulationResources(maximumLiveBytes: 128 * 1024 * 1024,
            maximumTemporaryBytes: capacity, maximumWorkUnits: 100_000_000,
            maximumHashedBytes: 1024 * 1024)
        let prepared = try await prepare("first preparation\nR1 out 0 1k\n.op\n.end\n", resources: owner,
            maximumElements: 8192, maximumTransformBytes: capacity)
        #expect(prepared.circuit.instances.count == 1)
        // The retained output is still live, but all preparation scratch has ended.
        let scratch = try owner.reserveStorage(kind: .temporaryBytes, byteCount: capacity)
        #expect(scratch.byteCount == capacity)
        withExtendedLifetime(prepared) {}
    }

    @Test func failedExactEncodingHashReleasesItsCapacityAndKeepsExistingScratchAdmitted() throws {
        let capacity: UInt64 = 64 * 1024 * 1024
        let owner = try SPICESimulationResources(maximumLiveBytes: 1024,
            maximumTemporaryBytes: capacity, maximumWorkUnits: 100_000,
            maximumHashedBytes: 1)
        let existing = try owner.reserveStorage(kind: .temporaryBytes, byteCount: capacity - 128)
        defer { withExtendedLifetime(existing) {} }
        // Exact framing fits the remaining 128 bytes. Hash admission fails only after emission.
        #expect(throws: SPICESimulationResources.ResourceError.hashLimit) {
            try SPICEPreparationEncoding.digest(domain: "identity-test-v1", maximumBytes: capacity,
                resources: owner) { encoding in
                try encoding.field("value")
                try encoding.integer(42)
            }
        }
        let released = try owner.reserveStorage(kind: .temporaryBytes, byteCount: 128)
        #expect(released.byteCount == 128)
    }

    @Test func exactEncodingPreservesFramingAndRejectsOneByteBelowRequiredCapacity() throws {
        let owner = try resources()
        var baseline = try SPICEPreparationEncoding(domain: "id", maximumBytes: 31, resources: owner)
        try baseline.field("value"); try baseline.integer(42)
        let expected = try baseline.digest()
        let actual = try SPICEPreparationEncoding.digest(domain: "id", maximumBytes: 31, resources: owner) {
            try $0.field("value"); try $0.integer(42)
        }
        #expect(actual == expected)
        #expect(throws: SPICESourceStorageError.arithmeticOverflow) {
            try SPICEPreparationEncoding.digest(domain: "id", maximumBytes: 30, resources: owner) {
                try $0.field("value"); try $0.integer(42)
            }
        }
    }
}
