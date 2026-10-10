import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceIO
import CoreSpiceMOSContracts
import Foundation
import Synchronization
import Testing

@Suite("Original Sky130 public source interpretation", .timeLimit(.minutes(2)))
struct Sky130OriginalSourceVerificationTests {
    private final class ObservedResources: SPICESourceResourceAccounting {
        let underlying: SPICESimulationResources
        private let work = Mutex<[SPICESourceWorkKind: UInt64]>([:])
        init(_ underlying: SPICESimulationResources) { self.underlying = underlying }
        func checkCancellation() throws { try underlying.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try underlying.charge(kind, units: units)
            // The underlying finite aggregate ceiling already admitted this sum without overflow.
            work.withLock { $0[kind, default: 0] += units }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try underlying.chargeHashedBytes(bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try underlying.reserveStorage(kind: kind, byteCount: byteCount)
        }
        var observedWork: [String: UInt64] {
            work.withLock { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
    }
    private struct Provider: SPICEExactSourceProviding {
        let sources: [SPICECheckedSource]
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            try work.checkCancellation()
            guard let source = sources.first(where: { $0.binding == binding }) else {
                throw SPICEExactSourceError.undeclaredSource(binding.key)
            }
            return source
        }
    }

    private func capture(_ data: Data, key: String, resources: any SPICESourceResourceAccounting) throws -> SPICECheckedSource {
        let bytes = Array(data)
        let hash = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: key, reference: try ArtifactReference(digest: hash.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        return try .admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 65536)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"] != nil,
                   "Requires explicit unchanged original Sky130 source root"))
    func selectedOriginalTTDeclarationAndExactReleaseRefusal() async throws {
        let rootPath = try #require(ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"])
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let spice = rootURL.appendingPathComponent("libs.ref/sky130_fd_pr/spice", isDirectory: true)
        let modelPath = spice.appendingPathComponent("sky130_fd_pr__nfet_01v8__tt.pm3.spice").path
        let mismatchPath = spice.appendingPathComponent("sky130_fd_pr__nfet_01v8__mismatch.corner.spice").path
        let resources = ObservedResources(try SPICESimulationResources(maximumLiveBytes: 2_000_000_000,
            maximumTemporaryBytes: 1_000_000_000, maximumWorkUnits: 10_000_000_000,
            maximumHashedBytes: 64_000_000))
        let reader = LocalSPICESourceReader()
        let model = try capture(reader.read(at: modelPath, maximumByteCount: 2_000_000, maximumPageByteCount: 65536),
            key: modelPath, resources: resources)
        let mismatch = try capture(reader.read(at: mismatchPath, maximumByteCount: 2_000_000, maximumPageByteCount: 65536),
            key: mismatchPath, resources: resources)
        // Caller inputs match sky130.lib.spice TT switches and all.spice micron scale.
        let wrapper = """
        original Sky130 TT selection and exact release admission
        .param mc_mm_switch=0 mc_pr_switch=0
        .option scale=1u
        .include "original-nfet-tt"
        .include "original-nfet-mismatch"
        VD d 0 1
        VG g 0 1.2
        X1 d g 0 0 sky130_fd_pr__nfet_01v8 w=0.65 l=0.15 nf=1
        .op
        .end
        """
        let caller = try capture(Data(wrapper.utf8), key: "sky130-original-caller", resources: resources)
        let admittedSources = [caller, model, mismatch]
        let sourceBytes = try admittedSources.reduce(UInt64(0)) { total, source in
            let (next, overflow) = total.addingReportingOverflow(source.binding.reference.byteCount)
            try #require(!overflow)
            return next
        }
        let longestSourceKeyBytes = UInt64(admittedSources.map { $0.binding.key.utf8.count }.max() ?? 0)
        let maximumPrograms = 100_000
        // Each assignment scans location.file, origin.captureID and origin.location.file.
        // Sixteen additional source-sized passes are explicit caller headroom, not an exact work bound.
        let (coordinateWork, coordinateOverflow) = longestSourceKeyBytes.multipliedReportingOverflow(by: UInt64(3 * maximumPrograms))
        let (passHeadroom, headroomOverflow) = sourceBytes.multipliedReportingOverflow(by: 16)
        let (resolutionWorkLimit, workOverflow) = coordinateWork.addingReportingOverflow(passHeadroom)
        try #require(!coordinateOverflow && !headroomOverflow && !workOverflow)
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "original-sky130-tt-v1",
            configuration: configuration, resources: resources, maximumPageByteCount: 65536)
        let resolution = try MOSResolutionLimits(maximumRetainedBytes: 512_000_000, maximumDiagnosticBytes: 1_000_000,
            maximumScopeDepth: 32, maximumSymbols: 4096, maximumScopes: 32,
            maximumInvocations: 32, maximumInvocationBindings: 4096, maximumDeclarations: 256,
            maximumPrograms: maximumPrograms, maximumBindings: 4096, maximumFunctions: 64,
            maximumFunctionDepth: 32, maximumExpressionNodes: 512, maximumExpressionDepth: 128,
            maximumCandidates: 256, maximumCacheEntries: 200_000, maximumEvaluationSteps: resolutionWorkLimit)
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 1000, maximumSolveAttempts: 10000,
            maximumNewtonIterations: 100000, maximumSavedScalars: 10000, maximumMatrixDimension: 64,
            maximumWorkUnits: 100000000, maximumBreakpoints: 1000)
        let input = try await SPICESimulationPreparer().prepare(.init(root: caller, environment: environment,
            catalog: [caller.binding, model.binding, mismatch.binding],
            routes: [.init(parentKey: caller.binding.key, childKey: modelPath, literalRoute: "original-nfet-tt", kind: .include),
                     .init(parentKey: caller.binding.key, childKey: mismatchPath, literalRoute: "original-nfet-mismatch", kind: .include)],
            provider: Provider(sources: [model, mismatch]), configuration: configuration,
            operatingPolicy: .recordActual,
            // Original files have 198 non-continuation statements, including 180 models.
            // 8192 metadata entries admit headroom without charging every coefficient as an IO element.
            // 1,138,511 source bytes * 64 + 8192 * 4096 = 106,419,136 transform bytes.
            // Frontend reserves 1,024,000,000 live plus 512,000,000 temporary bytes;
            // simultaneous transform + frontend: 1,130,419,136 live / 618,419,136 temporary.
            limits: .init(maximumElements: 8192, maximumTransformBytes: 512_000_000,
                maximumSweepPoints: 1, maximumPageByteCount: 65536, numerical: numerical),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: resolution), resources: resources)
        let netlist = input.netlist
        let ioElements = 1 + netlist.components.count + netlist.models.count + netlist.controls.count
            + netlist.parameters.count + netlist.initialConditions.count + netlist.nodeSets.count
            + netlist.analyses.count + netlist.dependencyEvents.count + input.sources.count + 1
        #expect(ioElements <= 8192)
        let instance = try #require(input.circuit.instances.first { $0.mos != nil })
        guard case .resolved(let resolved) = instance.mos else {
            Issue.record("Original MOS source did not retain typed resolution"); return
        }
        let snapshot = input.lowered.snapshot
        let declaration = try snapshot.declaration(resolved.declaration)
        let selected = try snapshot.name(of: resolved.selectedName)
        let expected = "sky130_fd_pr__nfet_01v8__model.98"
        #expect(selected == expected && declaration.originalName == expected)
        #expect(resolved.identitySpace == snapshot.identitySpace && resolved.scope == declaration.scope)
        #expect(resolved.source == declaration.source && resolved.source.path == modelPath)
        let sourceLine = try #require(resolved.source.line)
        #expect(sourceLine == 26597)
        #expect(resolved.source.occurrenceID != nil && resolved.source.statementByteOffset != nil)
        #expect(resolved.release == .bsim4_4_5 && declaration.version == "4.5" && declaration.level == 54)
        #expect(resolved.rawGeometry.width == 0.65 && resolved.rawGeometry.length == 0.15)
        #expect(resolved.geometryScale == 1e-6)
        let width = try #require(resolved.normalizedGeometry.width)
        let length = try #require(resolved.normalizedGeometry.length)
        #expect(abs(width - 650e-9) <= 1e-21 && abs(length - 150e-9) <= 1e-21)
        #expect(resolved.selectionGeometry.width == width && resolved.selectionGeometry.length == length)
        #expect(resolved.selectionGeometry.fingerDivisor == 1)
        let candidate = try #require(resolved.candidates.first { $0.disposition == .selected })
        #expect(candidate.declaration == declaration.id)
        let bounds = try #require(candidate.bounds)
        #expect(bounds.widthMinimum == 640e-9 && bounds.widthMaximum == 650e-9)
        #expect(bounds.lengthMinimum == 150e-9 && bounds.lengthMaximum == 180e-9)
        #expect(input.lowered.evaluationProvenance.profile == .pinnedNgspiceNormalV1)
        #expect(input.configuration.seed == 42 && input.lowered.evaluationProvenance.seed == 42)
        #expect(Set(input.sources.map { $0.binding.key }) == Set([caller.binding.key, modelPath, mismatchPath]))
        let operating = try input.configuration.options.operatingConditions()
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: 16, maximumMatrixDimension: 64,
            maximumAllocationBytes: 16_000_000,
            mosPreparationLimits: try .init(maximumRetainedBytes: 2_000_000, maximumTemporaryBytes: 2_000_000,
                maximumDiagnosticBytes: 1_000_000, maximumWorkUnits: 1_000_000),
            mosPreparationConditions: try .init(ambientKelvin: operating.temperatureKelvin,
                nominalKelvin: operating.nominalTemperatureKelvin, analysisCapabilities: .dc, maximumStressIterations: 1))
        do {
            _ = try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                operatingConditions: operating, limits: limits, numericalLimits: numerical, resources: resources)
            Issue.record("Exact original BSIM4 4.5 source admitted numerical ownership"); return
        } catch SPICENativePreparationError.mosPreparation(.unsupportedRelease(.bsim4_4_5)) { }
        if let output = ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_PROOF"] {
            let facts: [String: Any] = ["status": "observed", "selectedModel": selected,
                "release": resolved.release.rawValue, "declarationID": declaration.id.rawValue,
                "sourcePath": modelPath, "sourceLine": sourceLine,
                "normalizedWidth": width, "normalizedLength": length,
                "geometryScale": resolved.geometryScale, "fingerDivisor": resolved.selectionGeometry.fingerDivisor,
                "seed": input.configuration.seed, "randomDraws": input.lowered.evaluationProvenance.randomDraws,
                "evaluationSteps": input.lowered.evaluationProvenance.evaluationSteps,
                "sharedResourceWorkByKind": resources.observedWork,
                "actualAdmittedSourceBytes": sourceBytes, "longestSourceKeyBytes": longestSourceKeyBytes,
                "maximumPrograms": maximumPrograms, "maximumResolutionWork": resolutionWorkLimit,
                "resolutionWorkPolicy": "3 * longest UTF8 source key bytes * maximumPrograms + 16 * actual admitted source bytes; caller headroom, not exact work proof",
                "declarationCount": snapshot.declarations.count, "candidateCount": resolved.candidates.count,
                "ioElements": ioElements, "maximumIOElements": 8192,
                "refusal": "mosPreparation.unsupportedRelease.bsim4_4_5",
                "sources": input.sources.map { ["path": $0.binding.key, "bytes": $0.binding.reference.byteCount,
                    "digest": String(describing: $0.binding.reference.digest)] as [String: Any] }]
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }
}
