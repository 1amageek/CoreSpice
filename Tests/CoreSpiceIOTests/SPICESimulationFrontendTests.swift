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

    @Test func transientMethodIdentityBindsCheckedStartupAndLTESemantics() async throws {
        let text = "transient semantic identity\n.options method=be\nR1 out 0 1k\nC1 out 0 1u\n.tran 1u 10u uic\n.end\n"
        let first = try await prepare(text, resources: resources())
        let repeated = try await prepare(text, resources: resources())
        guard case .transient(let configuration) = first.configuration.analysis else {
            Issue.record("Missing transient configuration"); return
        }
        #expect(configuration.preferredMethod == .backwardEuler)
        #expect(first.configuration.identity == repeated.configuration.identity)
        // Captured from this exact preparation before the transient rule marker was added.
        // The former METHOD=be semantics used BE only initially, then switched to TRAP.
        let legacyIdentity = "2f28659b70f1e34192399c7750e038129a0708e6ae7ed5ed1208c563a851711a"
        #expect(first.configuration.identity.hexadecimalValue != legacyIdentity)
        // Same source/settings under checked startup before minimum-step admission was corrected.
        let previousCheckedIdentity = "946806ebe37c3a5da354f2f0f28645da457fc1e8d097b5106055bba3e9f0818e"
        #expect(first.configuration.identity.hexadecimalValue != previousCheckedIdentity)
        // Same preparation before Newton rejection was allowed to retry the exact minimum.
        let previousMinimumProposalIdentity = "3c8f75f810c573fac69ff9d9da9fcf69dca752a23dda635a0ae23f612ba6df89"
        #expect(first.configuration.identity.hexadecimalValue != previousMinimumProposalIdentity)
        let previousNewtonMinimumIdentity = "aed4de28b3b0807fac3579de5616df74bdea099c679eeebed963a399cfc6eec8"
        #expect(first.configuration.identity.hexadecimalValue != previousNewtonMinimumIdentity)
        print("TRANSIENT_EFFECTIVE_RULE_DIGEST \(first.configuration.identity)")
    }

    @Test(arguments: ["op", "dc", "tran"])
    func newtonNumericalRuleIdentity(_ kind: String) async throws {
        let directive = kind == "op" ? ".op" : kind == "dc" ? ".dc V1 0 1 .5" : ".tran 1u 10u uic"
        let text = "Newton numerical identity\nV1 in 0 1\nR1 in out 1k\nC1 out 0 1u\n\(directive)\n.end\n"
        let first = try await prepare(text, resources: resources())
        let repeated = try await prepare(text, resources: resources())
        #expect(first.configuration.identity == repeated.configuration.identity)
        let previous = ["op": "ecfad889d8f57a79edfd4a0c2a902c6fd9d02ed5665d73855085f70a3ecdf514",
            "dc": "1cdbb33afb1e350342f31ef8166f46ddba66b9ef1a488f9501af167b70e15fc6",
            "tran": "7257ca9b71b16c7076958a44e60a190455108a8d821a133c57587ca6f3f01efa"]
        #expect(first.configuration.identity.hexadecimalValue != previous[kind])
        print("NEWTON_RULE_IDENTITY kind=\(kind) digest=\(first.configuration.identity.hexadecimalValue)")
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

    @Test func capacityRefusalPreservesQuantityAndReleasesOwners() async throws {
        let text = "capacity refusal\nR1 out 0 1k\n.op\n.end\n"
        for elements in [1, 128] {
            let owner = try resources()
            do {
                _ = try await prepare(text, resources: owner, maximumElements: elements,
                    maximumTransformBytes: elements == 1 ? 1_000_000 : 1)
                Issue.record("Insufficient caller capacity published a prepared input")
            } catch let error as SPICESimulationPreparationError {
                guard case .resource(let cause) = error,
                      let capacity = cause as? SPICESimulationCapacityError else {
                    Issue.record("Capacity was misclassified: \(error)"); continue
                }
                switch capacity {
                case .elements(let boundary, let limit, let requested):
                    #expect(elements == 1 && boundary == .parsedTransform && limit == 1 && requested > limit)
                case .transformBytes(let limit, let requested):
                    #expect(elements == 128 && limit == 1 && requested > limit)
                }
            }
            let live = try owner.reserveStorage(kind: .liveOwnedBytes, byteCount: 64 * 1024 * 1024)
            let temporary = try owner.reserveStorage(kind: .temporaryBytes, byteCount: 64 * 1024 * 1024)
            withExtendedLifetime((live, temporary)) {}
        }
    }

    @Test func expandedHierarchyCapacityRefusesAtTheLoweredOwnerBoundary() async throws {
        for expected in [SPICESimulationCapacityError.Boundary.loweredInstances, .loweredNodes] {
            let body = expected == .loweredInstances ? "R1 p x 1k\nR2 x y 1k\nR3 y 0 1k\n" : "R1 x y 1k\n"
            let text = "expanded capacity\n.subckt cell p\n" + body + ".ends\n"
                + (0..<26).map { "X\($0) n\($0) cell\n" }.joined() + ".op\n.end\n"
            let owner = try resources()
            do {
                _ = try await prepare(text, resources: owner, maximumElements: 50)
                Issue.record("Expanded hierarchy escaped the caller element limit")
            } catch let error as SPICESimulationPreparationError {
                guard case .resource(let cause) = error,
                      let capacity = cause as? SPICESimulationCapacityError,
                      case .elements(let boundary, let limit, let requested) = capacity else {
                    Issue.record("Expanded capacity was misclassified: \(error)"); continue
                }
                #expect(boundary == expected && limit == 50 && requested > limit)
            }
            let live = try owner.reserveStorage(kind: .liveOwnedBytes, byteCount: 64 * 1024 * 1024)
            let temporary = try owner.reserveStorage(kind: .temporaryBytes, byteCount: 64 * 1024 * 1024)
            withExtendedLifetime((live, temporary)) {}
        }
    }
    @Test func sharedDCScheduleIncludesDecimalEndpointsWithoutNongridOvershoot() async throws {
        let cases: [(String, [Double])] = [
            (".5 .6 .1", [0.5, 0.6]),
            (".6 .5 -.1", [0.6, 0.5]),
            ("0 .9 .3", [0, 0.3, 0.6, 0.9]),
            ("0 -.9 -.3", [0, -0.3, -0.6, -0.9]),
            ("0 1 .3", [0, 0.3, 0.6, 3 * 0.3]),
            ("0 1 .6", [0, 0.6]),
            ("0 .3 .1", [0, 0.1, 0.2, 0.3])
        ]
        for (schedule, expected) in cases {
            let input = try await prepare("fractional sweep\nV1 out 0 0\nR1 out 0 1k\n.dc V1 \(schedule)\n.end\n", resources: resources())
            guard case .dc(_, let values, _) = input.configuration.analysis else {
                Issue.record("Missing prepared DC schedule"); continue
            }
            #expect(values.map(\.bitPattern) == expected.map(\.bitPattern))
        }
        for (schedule, reason) in [("0 1 -.1", "DC sweep direction"), ("0 10000 1", "DC sweep point ceiling")] {
            do {
                _ = try await prepare("invalid schedule\nV1 out 0 0\nR1 out 0 1k\n.dc V1 \(schedule)\n.end\n", resources: resources())
                Issue.record("Invalid prepared DC schedule succeeded")
            } catch let error as SPICESimulationPreparationError {
                guard case .unsupportedCapability(let actual) = error else { throw error }
                #expect(actual == reason)
            }
        }
        var callbacks = 0
        #expect(throws: SPICEDCSweepSchedule.Failure.self) {
            _ = try SPICEDCSweepSchedule.values(from: 0.5, through: 0.6, by: 0.1, maximumCount: 1) { callbacks += 1 }
        }
        #expect(callbacks == 0)
        #expect(throws: SPICEDCSweepSchedule.Failure.self) {
            _ = try SPICEDCSweepSchedule.values(from: 0, through: 1, by: -0.1, maximumCount: 10)
        }
        #expect(throws: SPICEDCSweepSchedule.Failure.self) {
            _ = try SPICEDCSweepSchedule.values(from: 0, through: .infinity, by: 0.1, maximumCount: 10)
        }
        let adjacentStart = (0.9).nextDown
        let startOnly = try SPICEDCSweepSchedule.values(from: adjacentStart, through: 0.9, by: 1, maximumCount: 2)
        #expect(startOnly.map(\.bitPattern) == [adjacentStart.bitPattern])
        do {
            _ = try SPICEDCSweepSchedule.values(from: 1, through: (1.0).nextUp,
                by: Double.ulpOfOne / 2, maximumCount: 4)
            Issue.record("Repeated DC grid coordinate succeeded")
        } catch let failure as SPICEDCSweepSchedule.Failure {
            guard case .nonAdvancingPoint = failure else { throw failure }
        }
    }

}
