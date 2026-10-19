import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import OSDIContracts
import Testing
import Synchronization

@Suite("Original MOS external source boundary", .timeLimit(.minutes(1)))
struct ExternalMOSPreparationTests {
    // This preparer tests source association only; it does not implement or qualify model physics.
    enum Fault: Sendable, Equatable { case none, badAddress, swallowedAddress, wrongValue, wrongModel, wrongCandidate }
    private struct SourceFixture: ExternalMOSPreparing {
        var identity: String = "source-boundary-fixture.v1"
        var fault: Fault = .none
        var replacedSource: ExternalMOSSourceRequest?
        func prepare(_ source: ExternalMOSSourceRequest,
                     evaluate: (ExternalMOSScalarAddress) throws -> Double,
                     chargeWork: () throws -> Void) throws -> ExternalMOSPreparation {
            if fault == .badAddress { _ = try evaluate(.instance(index: -1)) }
            if fault == .swallowedAddress {
                do { _ = try evaluate(.instance(index: -1)) }
                catch { /* The Lowering owner must preserve this failure even if a profile catches it. */ }
            }
            let id = try #require(source.candidateDeclarations.first)
            let declaration = try source.snapshot.declaration(id)
            _ = try source.originalModel(for: id, chargeWork: chargeWork)
            var facts: [ExternalMOSParameterFact] = []
            var model: [OSDIParameterAssignment] = []
            var instance: [OSDIParameterAssignment] = []
            var length = 1.0, width = 1.0, multiplier = 1.0
            for (index, binding) in source.resolution.bindings.enumerated() {
                try chargeWork()
                let address = ExternalMOSScalarAddress.instance(index: index)
                let name = try source.snapshot.name(of: binding.symbol)
                let raw = try evaluate(address)
                #expect(try evaluate(address) == raw)
                let normalized: Double
                if name == "l" { length = raw; normalized = raw * source.resolution.geometryScale }
                else if name == "w" { width = raw; normalized = raw * source.resolution.geometryScale }
                else { normalized = raw }
                if name == "m" { multiplier = raw }
                instance.append(try .init(name: name, scope: .instance, value: .real(normalized)))
                facts.append(.init(address: address, name: name, role: .instance,
                    rawValue: fault == .wrongValue ? raw.nextUp : raw, normalizedValue: normalized,
                    providerValue: .real(normalized), isGiven: true))
            }
            for (index, binding) in declaration.coefficients.enumerated() {
                try chargeWork()
                let address = ExternalMOSScalarAddress.model(declaration: id, index: index)
                let name = try source.snapshot.name(of: binding.symbol), raw = try evaluate(address)
                model.append(try .init(name: name, scope: .model, value: .real(raw)))
                facts.append(.init(address: address, name: name, role: .model, rawValue: raw,
                    normalizedValue: raw, providerValue: .real(raw), isGiven: true))
            }
            if let version = declaration.version {
                model.append(try .init(name: "version", scope: .model, value: .string(version)))
                facts.append(.init(address: nil, name: "version", role: .model, rawValue: nil,
                    normalizedValue: nil, providerValue: .string(version), isGiven: true))
            }
            let reference = try ArtifactReference(digest: .init(algorithm: .sha256,
                hexadecimalValue: String(repeating: "a", count: 64)), byteCount: 123,
                descriptor: .init(role: .input, kind: .model, format: .unknown))
            let binding = try OSDIModelBinding(modelName: fault == .wrongModel ? "other" : declaration.originalName,
                artifact: reference, descriptorIndex: 0, expectedDescriptorName: "source-fixture",
                modelParameters: model)
            let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: instance, previousState: [])
            return .init(source: replacedSource ?? source,
                selectedDeclaration: fault == .wrongCandidate ? MOSDeclarationID(.max) : id,
                resolved: resolved, facts: .init(profileIdentity: identity,
                    geometry: .init(rawLength: length, rawWidth: width,
                        effectiveLengthSI: length * source.resolution.geometryScale,
                        totalWidthSI: width * source.resolution.geometryScale,
                        selectionLengthSI: length * source.resolution.geometryScale,
                        selectionWidthSI: width * source.resolution.geometryScale,
                        fingerCount: 1, parallelMultiplier: multiplier, widthInputIsPerFinger: false), parameters: facts))
        }
    }

    private func parsed(_ source: String) async throws -> ParsedNetlist {
        try await SPICEParser().parse(document: .init(text: source, resolvedPath: "original-m.cir", captureID: "original-source"),
            configuration: .default, fileResolver: NullFileResolver()).get()
    }
    private func lower(_ source: ParsedNetlist, selections: [String: any ExternalMOSPreparing]) throws -> LoweredCircuit {
        let limits = try OSDIFrontendTests().limits()
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 19)
        try session.lower(externalMOSPreparers: selections)
        return try session.finish()
    }
    private let single = "Original MOS\n.model n nmos level=54 version=4.5 vth0=.4\nM1 d g 0 0 n l=1u w=4u\n.op\n.end\n"

    @Test func noSelectionRetainsOriginalMigrationFailure() async throws {
        let source = try await parsed(single)
        do { _ = try lower(source, selections: [:]); Issue.record("Unselected original M was admitted") }
        catch let error as MOSResolutionFailure {
            guard case .osdiBindingRequired(let level, let version, let location) = error else { throw error }
            #expect(level == 54 && version == "4.5")
            #expect(location.captureID == "original-source" && location.line == 2)
        }
    }

    @Test func originalHierarchyScopeParametersAndMultiplicityRemainSourceBound() async throws {
        let source = try await parsed("""
        Original scoped MOS
        .options scale=1u
        .model n nmos level=54 version=4.5 vth0=.9
        .subckt cell d g params: len=2
        .model n pmos level=54 version=4.5.0 vth0=.4
        M1 d g 0 0 n l={len+rand()} w=4 m=99
        .ends
        X1 out in cell len=3 m=2
        .op
        .end
        """)
        let result = try lower(source, selections: ["x1.m1": SourceFixture()])
        let checked = try #require(result.externalMOSPreparations.first)
        let request = checked.preparation.source
        let declaration = try result.snapshot.declaration(checked.preparation.selectedDeclaration)
        #expect(request.original.type == .mosfet)
        #expect(request.original == source.subcircuits.first?.body.components.first)
        #expect(request.resolution.instance == "x1.m1" && request.resolution.scopeInstantiation != 0)
        #expect(request.candidateInvocation != 0 && declaration.polarity == .pmos)
        #expect(declaration.version == "4.5.0" && declaration.source.captureID == "original-source")
        #expect(request.terminals == ["out", "in", "0", "0"])
        #expect(request.resolution.geometryScale == 1e-6)
        #expect(checked.preparation.facts.geometry.parallelMultiplier == 2)
        #expect(result.evaluationProvenance.randomDraws == 1)
        #expect(result.circuit.instances.count == 1 && result.circuit.instances[0].mos == nil)
        #expect(result.circuit.instances[0].osdi?.resolved == checked.preparation.resolved)
        #expect(result.compiled.source.subcircuits.first?.body.components.first?.type == .mosfet)
        #expect(result.compiled.source.models.first?.type == .nmos)
    }

    @Test(arguments: [Fault.badAddress, .swallowedAddress, .wrongValue, .wrongModel, .wrongCandidate])
    func invalidSourceClaimsRefuseWithoutPublishingCircuit(fault: Fault) async throws {
        let source = try await parsed(single), limits = try OSDIFrontendTests().limits()
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 19)
        do {
            try session.lower(externalMOSPreparers: ["m1": SourceFixture(fault: fault)])
            Issue.record("Invalid external source claim was published")
        } catch is ExternalMOSPreparationFailure { }
        #expect(session.circuit == nil)
        do { _ = try session.finish(); Issue.record("Poisoned run was finished") }
        catch is MOSResolutionFailure { }
    }

    @Test func sourceFromAnotherRunAndUnusedSelectionsRefuse() async throws {
        let source = try await parsed(single)
        let first = try lower(source, selections: ["m1": SourceFixture()])
        let previous = try #require(first.externalMOSPreparations.first?.preparation.source)
        #expect(throws: ExternalMOSPreparationFailure.sourceMismatch) {
            _ = try lower(source, selections: ["m1": SourceFixture(replacedSource: previous)])
        }
        let catalogs: [[String: any ExternalMOSPreparing]] = [["M1": SourceFixture()], ["m1": SourceFixture(), "typo": SourceFixture()]]
        for selections in catalogs {
            #expect(throws: ExternalMOSPreparationFailure.self) { _ = try lower(source, selections: selections) }
        }
    }

    private struct NoDependencies: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }
    private func prepared(_ text: String, fixture: SourceFixture = .init()) async throws -> PreparedSPICESimulation {
        let resources = try SPICESimulationResources(maximumLiveBytes: 64 * 1024 * 1024,
            maximumTemporaryBytes: 64 * 1024 * 1024, maximumWorkUnits: 100_000_000, maximumHashedBytes: 1024 * 1024)
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "root", reference: try .init(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 64)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "external-mos-source-test.v1",
            configuration: parser, resources: resources, maximumPageByteCount: 64)
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 100, maximumSolveAttempts: 200,
            maximumNewtonIterations: 1000, maximumSavedScalars: 1000, maximumMatrixDimension: 32,
            maximumWorkUnits: 100_000, maximumBreakpoints: 100)
        let adapter = try SPICEExternalMOSPreparer(preparer: fixture, resources: resources)
        return try await SPICESimulationPreparer().prepare(.init(root: root, environment: environment,
            catalog: [binding], routes: [], provider: NoDependencies(), configuration: parser,
            operatingPolicy: .recordActual, limits: .init(maximumElements: 128, maximumTransformBytes: 1024 * 1024,
                maximumSweepPoints: 20, maximumPageByteCount: 64, numerical: numerical),
            profile: .pinnedNgspiceNormalV1, seed: 19, resolutionLimits: OSDIFrontendTests().limits(),
            externalMOSPreparers: ["m1": adapter]), resources: resources)
    }

    @Test func actualIOPreparationAndFreshReprepareRetainOriginalSourceAndProfileIdentity() async throws {
        let text = "Original MOS\n.param width=4\n.options scale=1u\n.model n nmos level=54 version=4.5 vth0=.4\nM1 d g 0 0 n l=1 w={width}\n.op\n.end\n"
        let original = try await prepared(text)
        let changed = try SPICESimulationPreparer().reprepare(original, parameterOverrides: ["width": 6])
        let first = try #require(original.lowered.externalMOSPreparations.first)
        let second = try #require(changed.lowered.externalMOSPreparations.first)
        #expect(first.preparation.source !== second.preparation.source)
        #expect(first.preparation.source.original == second.preparation.source.original)
        #expect(original.sourceInputIdentity == changed.sourceInputIdentity)
        #expect(first.preparation.facts.geometry.totalWidthSI == 4e-6)
        #expect(second.preparation.facts.geometry.totalWidthSI == 6e-6)
        #expect(original.configuration.identity != changed.configuration.identity)
        let differentProfile = try await prepared(text, fixture: .init(identity: "source-boundary-fixture.v2"))
        #expect(original.sourceInputIdentity == differentProfile.sourceInputIdentity)
        #expect(original.configuration.identity != differentProfile.configuration.identity)
        #expect(original.netlist.components.first?.type == .mosfet)
        #expect(original.netlist.models.first?.type == .nmos)
    }

    private enum ResourceRefusal: Error, Equatable { case cancelled, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State { var live: UInt64 = 0; var cancelled = false }
        private let state = Mutex(State())
        let limit: UInt64
        init(limit: UInt64 = 4096) { self.limit = limit }
        var live: UInt64 { state.withLock { $0.live } }
        func cancel(_ value: Bool) { state.withLock { $0.cancelled = value } }
        func checkCancellation() throws { if state.withLock({ $0.cancelled }) { throw ResourceRefusal.cancelled } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try checkCancellation() }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try checkCancellation() }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            try state.withLock { value in
                guard byteCount <= limit - value.live else { throw ResourceRefusal.storage }
                value.live += byteCount
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { $0.live -= byteCount } }
        }
    }
    @Test func adapterMetadataAdmissionCancellationAndExplicitRetryPreserveLease() async throws {
        let source = try await parsed(single), resources = Resources()
        do {
            let adapter = try SPICEExternalMOSPreparer(preparer: SourceFixture(), resources: resources)
            resources.cancel(true)
            #expect(throws: ResourceRefusal.cancelled) { _ = try lower(source, selections: ["m1": adapter]) }
            resources.cancel(false)
            let result = try lower(source, selections: ["m1": adapter])
            #expect(result.externalMOSPreparations.count == 1)
            withExtendedLifetime(adapter) { #expect(resources.live > 0) }
        }
        #expect(resources.live == 0)
        let exhausted = Resources(limit: 1)
        #expect(throws: ResourceRefusal.storage) {
            _ = try SPICEExternalMOSPreparer(preparer: SourceFixture(), resources: exhausted)
        }
        #expect(exhausted.live == 0)
    }

}
