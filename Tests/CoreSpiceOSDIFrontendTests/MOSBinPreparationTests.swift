import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParser
import CoreSpiceParserSPICE
import CoreSpiceParsedIR
import OSDIContracts
import Testing
import Synchronization
import CircuiteFoundationCrypto

@Suite("External MOS bin and geometry preparation", .timeLimit(.minutes(1)))
struct MOSBinPreparationTests {
    @Test func scaledTotalWidthNFMultiplicityAndTypedGiven() async throws {
        let result = try await lower("""
        .options scale=1u wnflag=1
        .model bins.0 pmos level=54 version=4.5 lmin=.9u lmax=1.1u wmin=1.9u wmax=2.1u mode=2
        M1 d g 0 0 bins l=1 w=8 nf=4 m=3 ad=2
        """)
        let checked = try #require(result.externalMOSPreparations.first)
        let prepared = checked.preparation
        let g = prepared.facts.geometry
        #expect(g.rawWidth == 8 && g.rawLength == 1)
        #expect(g.effectiveLengthSI == 1e-6 && g.totalWidthSI == 8e-6)
        #expect(g.selectionWidthSI == 2e-6 && g.fingerCount == 4 && g.parallelMultiplier == 3)
        let assignments = prepared.resolved.instanceParameters
        #expect(assignments.first(where: { $0.name == "w" })?.value == .real(8e-6))
        #expect(assignments.first(where: { $0.name == "nf" })?.value == .real(4))
        #expect(assignments.first(where: { $0.name == "m" })?.value == .real(3))
        #expect(assignments.first(where: { $0.name == "ad" })?.value == .real(2 * 1e-6 * 1e-6))
        #expect(prepared.resolved.binding.modelParameters.contains { $0.name == "pmos" && $0.value == .integer(1) })
        #expect(prepared.resolved.binding.modelParameters.contains { $0.name == "mode" && $0.value == .integer(2) })
        #expect(prepared.resolved.binding.modelParameters.contains { $0.name == "version" && $0.value == .string("4.5") })
        #expect(prepared.source.snapshot.declarations[0].source.captureID == "bin-fixture")
        #expect(prepared.source.snapshot.declarations[0].source.line == 3)
        #expect(prepared.source.snapshot.declarations[0].source.statementByteOffset != nil)
        #expect(prepared.facts.parameters.filter { $0.providerValue != nil }.count
            == assignments.count + prepared.resolved.binding.modelParameters.count)
        for fact in prepared.facts.parameters where fact.address != nil {
            #expect(checked.evaluatedScalars.contains { $0.address == fact.address && $0.value.bitPattern == fact.rawValue?.bitPattern })
        }
    }

    @Test func omittedNFAndMDoNotBecomeGiven() async throws {
        let result = try await lower(".model exact nmos level=54 version=4.5\nM1 d g 0 0 exact l=1u w=4u")
        let p = try #require(result.externalMOSPreparations.first?.preparation)
        #expect(p.facts.geometry.fingerCount == 1 && p.facts.geometry.parallelMultiplier == 1)
        #expect(!p.resolved.instanceParameters.contains { $0.name == "nf" || $0.name == "m" })
        #expect(p.facts.parameters.contains { $0.name == "nf" && !$0.isGiven && $0.providerValue == nil })
        #expect(p.facts.parameters.contains { $0.name == "m" && !$0.isGiven && $0.providerValue == nil })
        #expect(p.resolved.binding.modelParameters.contains { $0.name == "nmos" && $0.value == .integer(1) })
    }

    @Test func captureLabelWithoutPhysicalSourceOffsetsStillRefuses() async throws {
        let parsed = try await SPICEParser().parse(document: .init(text:
            "External bins\n.model exact nmos level=54 version=4.5\nM1 d g 0 0 exact l=1u w=4u\n.end\n",
            resolvedPath: "bins.cir", captureID: "bin-fixture"), configuration: .default,
            fileResolver: NullFileResolver()).get()
        let model = try #require(parsed.models.first)
        #expect(model.origin?.captureID == "bin-fixture")
        #expect(model.origin?.statementByteOffset == nil)
        let limits = try limits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1,
            limits: limits, seed: 42)
        let actualProfile = try await profile()
        let preparer = try MOSBinExternalPreparer(profile: actualProfile, resources: resourceOwner(),
            maximumIdentityBytes: 1_000_000)
        do {
            try session.lower(externalMOSPreparers: ["m1": preparer])
            Issue.record("A capture label replaced missing physical source authority")
        } catch let error as MOSBinPreparationError { #expect(error == .invalidSource("exact")) }
    }

    @Test func widthConventionsAreExplicit() async throws {
        let p = try await profile(sourceWidth: .perFinger, providerWidth: .perFinger)
        let result = try await lower(".model exact nmos level=54 version=4.5\nM1 d g 0 0 exact l=1u w=2u nf=4", profile: p)
        let prepared = try #require(result.externalMOSPreparations.first?.preparation)
        #expect(prepared.facts.geometry.widthInputIsPerFinger)
        #expect(prepared.facts.geometry.totalWidthSI == 8e-6)
        #expect(prepared.resolved.instanceParameters.first(where: { $0.name == "w" })?.value == .real(2e-6))
    }

    @Test func closedBoundaryAmbiguityIsNotSilentlySourceOrdered() async throws {
        let body = """
        .model bins.0 nmos level=54 version=4.5 lmin=.5u lmax=1u wmin=1u wmax=3u
        .model bins.1 nmos level=54 version=4.5 lmin=1u lmax=2u wmin=1u wmax=3u
        M1 d g 0 0 bins l=1u w=2u
        """
        do { _ = try await lower(body); Issue.record("Shared boundary admitted without ordered profile") }
        catch let error as MOSBinPreparationError { #expect(error == .ambiguousBins) }
        let ordered = try await profile(order: .firstReverse)
        let result = try await lower(body, profile: ordered)
        let p = try #require(result.externalMOSPreparations.first?.preparation)
        #expect(p.source.snapshot.declarations[Int(p.selectedDeclaration.rawValue)].originalName == "bins.1")
    }

    @Test(arguments: ["nf=1.5", "nf=0", "m=0", "mode=2.5", "scale=2", "ad=-1"])
    func invalidNFMultiplicityIntegerFlagOrScaleFails(_ supplied: String) async throws {
        let modelFlag = supplied.hasPrefix("mode") ? supplied : ""
        let instanceFlag = supplied.hasPrefix("mode") ? "" : supplied
        do {
            _ = try await lower(".model exact nmos level=54 version=4.5 \(modelFlag)\nM1 d g 0 0 exact l=1u w=2u \(instanceFlag)")
            Issue.record("Invalid external source parameter admitted")
        } catch is MOSBinPreparationError {}
    }

    @Test(arguments: ["lmin=2u lmax=1u wmin=1u wmax=3u", "lmin=.5u lmax=2u wmin=1u"])
    func invalidOrMissingBoundsCannotDisappear(_ bounds: String) async throws {
        do {
            _ = try await lower(".model bins.0 nmos level=54 version=4.5 \(bounds)\nM1 d g 0 0 bins l=1u w=2u")
            Issue.record("Invalid candidate silently disappeared")
        } catch is MOSBinPreparationError {}
    }

    @Test func wrongVersionAndCanonicalAliasCollisionFail() async throws {
        for declaration in ["level=54 version=4.500000e+0", "level=54 version=4.5 mode=1 modealias=1"] {
            do {
                _ = try await lower(".model exact nmos \(declaration)\nM1 d g 0 0 exact l=1u w=2u")
                Issue.record("Version or alias mismatch admitted")
            } catch is MOSBinPreparationError {}
        }
    }

    @Test func nearestFamilyGapDoesNotFallBackToParent() async throws {
        let body = """
        .model bins.0 nmos level=54 version=4.5 lmin=.5u lmax=2u wmin=1u wmax=3u
        .subckt child d g
        .model bins.0 nmos level=54 version=4.5 lmin=4u lmax=8u wmin=1u wmax=3u
        M1 d g 0 0 bins l=1u w=2u
        .ends child
        X1 d g child
        """
        do { _ = try await lower(body, key: "x1.m1"); Issue.record("Parent family replaced nearer nonmatching family") }
        catch let error as MOSBinPreparationError { #expect(error == .noMatchingBin) }
    }

    @Test func exactDeclarationPrecedesItsFamily() async throws {
        let result = try await lower("""
        .model bins nmos level=54 version=4.5
        .model bins.0 nmos level=54 version=4.5 lmin=4u lmax=8u wmin=1u wmax=3u
        M1 d g 0 0 bins l=1u w=2u
        """)
        let p = try #require(result.externalMOSPreparations.first?.preparation)
        #expect(p.resolved.binding.modelName == "bins" && !p.source.isFamily)
    }

    @Test(arguments: ["scale=1e308", "scale=1e-300"])
    func geometryOverflowAndUnderflowRefuse(_ option: String) async throws {
        let dimensions = option == "scale=1e308" ? "l=2 w=2" : "l=1e-100 w=1e-100"
        do {
            _ = try await lower(".options \(option)\n.model exact nmos level=54 version=4.5\nM1 d g 0 0 exact \(dimensions)")
            Issue.record("Invalid scaled geometry published")
        } catch is MOSBinPreparationError {}
    }

    @Test func boundedIdentityCannotPublishTruncatedAuthority() async throws {
        let p = try await profile()
        #expect(throws: (any Error).self) {
            _ = try MOSBinExternalPreparer(profile: p, resources: resourceOwner(), maximumIdentityBytes: 1)
        }
    }

    @Test func qualifiedAliasesSurviveSameNameAcrossScopes() async throws {
        let p = try await profile(qualifiedWidth: true)
        let result = try await lower(".model exact nmos level=54 version=4.5 mw=2\nM1 d g 0 0 exact l=1u w=3u", profile: p)
        let prepared = try #require(result.externalMOSPreparations.first?.preparation)
        #expect(prepared.resolved.instanceParameters.contains { $0.name == "instance.w" && $0.value == .real(3e-6) })
        #expect(prepared.resolved.binding.modelParameters.contains { $0.name == "model.w" && $0.value == .real(2) })
        #expect(prepared.facts.parameters.contains { $0.name == "instance.w" && $0.providerValue == .real(3e-6) })
        #expect(prepared.facts.parameters.contains { $0.name == "model.w" && $0.providerValue == .real(2) })
        #expect(!prepared.resolved.instanceParameters.contains { $0.name == "w" })
    }

    @Test func ambiguousBareAliasStillRefuses() async throws {
        let p = try await profile(qualifiedWidth: false)
        do {
            _ = try await lower(".model exact nmos level=54 version=4.5\nM1 d g 0 0 exact l=1u w=3u", profile: p)
            Issue.record("Ambiguous unqualified setter was admitted")
        } catch let error as MOSBinPreparationError { #expect(error == .descriptorMismatch("w")) }
    }

    @Test func profileRetentionSharesOneLeaseAndRefundsAfterLastCopy() async throws {
        let resources = try ProfileResourceObserver()
        let p = try await profile()
        var first: MOSBinExternalPreparer? = try .init(profile: p, resources: resources, maximumIdentityBytes: 1_000_000)
        let charged = resources.live
        #expect(charged > UInt64(MemoryLayout<MOSBinExternalPreparer>.stride))
        var copy = first
        first = nil
        #expect(resources.live == charged && resources.temporary == 0)
        withExtendedLifetime(copy) {}
        copy = nil
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func requestCopiesRetainTheDelegateProfileLease() async throws {
        let resources = try ProfileResourceObserver()
        let p = try await profile()
        var preparer: MOSBinExternalPreparer? = try .init(profile: p, resources: resources, maximumIdentityBytes: 1_000_000)
        let profileCharge = resources.live
        var request: SPICESimulationPreparationRequest? = try quotaRequest(preparer: #require(preparer), resources: resources)
        var copy = request
        preparer = nil
        request = nil
        #expect(resources.live >= profileCharge && profileCharge > 0)
        withExtendedLifetime(copy) {}
        copy = nil
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func failedProfileConstructionRefundsRetainedAndTemporaryBytes() async throws {
        let resources = try ProfileResourceObserver()
        let p = try await profile()
        #expect(throws: (any Error).self) {
            _ = try MOSBinExternalPreparer(profile: p, resources: resources, maximumIdentityBytes: 1)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        let refused = try ProfileResourceObserver(maximumLiveBytes: 1)
        #expect(throws: (any Error).self) {
            _ = try MOSBinExternalPreparer(profile: p, resources: refused, maximumIdentityBytes: 1_000_000)
        }
        #expect(refused.live == 0 && refused.temporary == 0)
    }

    @Test func sameLabelDifferentRulesCannotShareIdentity() async throws {
        let resources = try resourceOwner()
        let first = try await profile(providerWidth: .total)
        let second = try await profile(providerWidth: .perFinger)
        let a = try MOSBinExternalPreparer(profile: first, resources: resources, maximumIdentityBytes: 1_000_000)
        let b = try MOSBinExternalPreparer(profile: second, resources: resources, maximumIdentityBytes: 1_000_000)
        #expect(first.label == second.label && a.identity != b.identity)
    }

    private func lower(_ body: String, profile supplied: ExternalMOSNormalizationProfile? = nil,
                       key: String = "m1") async throws -> LoweredCircuit {
        let resources = try resourceOwner()
        let text = try SPICEAccountedText.copy("External bins\n\(body)\n.end\n", resources: resources,
            maximumChunkByteCount: 256)
        let document = try SPICESourceDocument(accountedText: text, sourceKey: "bin-fixture",
            occurrenceID: .init(0), resolvedPath: "bins.cir")
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "external-bin-fixture",
            configuration: configuration, resources: resources, maximumPageByteCount: 256)
        let parsed = try await SPICEParser().parseProfile(document: document, configuration: configuration,
            environment: environment, resolver: BinFixtureNoDependencyResolver(), resources: resources)
        let limits = try limits()
        let compiled = try NetlistLowering.compile(parsed.netlist, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
        let actualProfile: ExternalMOSNormalizationProfile
        if let supplied { actualProfile = supplied } else { actualProfile = try await profile() }
        let preparer = try MOSBinExternalPreparer(profile: actualProfile, resources: resources, maximumIdentityBytes: 1_000_000)
        try session.lower(externalMOSPreparers: [key: preparer])
        return try session.finish()
    }

    private func quotaRequest(preparer: MOSBinExternalPreparer,
                              resources: ProfileResourceObserver) throws -> SPICESimulationPreparationRequest {
        let bytes = Array("Quota owner\n.end\n".utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "quota-root", reference: try .init(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span,
            resources: resources, maximumPageByteCount: 65536)
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: preparer.identity,
            configuration: configuration, resources: resources, maximumPageByteCount: 65536)
        return try .init(root: root, environment: environment, catalog: [binding], routes: [],
            provider: QuotaSourceProvider(source: root), configuration: configuration, operatingPolicy: .recordActual,
            limits: .init(maximumElements: 16, maximumTransformBytes: 4096, maximumSweepPoints: 1,
                maximumPageByteCount: 4096, numerical: .init(maximumAcceptedSteps: 1,
                    maximumSolveAttempts: 1, maximumNewtonIterations: 1, maximumSavedScalars: 16,
                    maximumMatrixDimension: 4, maximumWorkUnits: 1000, maximumBreakpoints: 1)),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: limits(),
            externalMOSPreparers: ["m1": preparer])
    }

    private func resourceOwner() throws -> SPICESimulationResources {
        try .init(maximumLiveBytes: 64_000_000, maximumTemporaryBytes: 64_000_000,
                  maximumWorkUnits: 10_000_000, maximumHashedBytes: 4_000_000)
    }

    private func limits() throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: 16_000_000, maximumDiagnosticBytes: 8192, maximumScopeDepth: 32,
            maximumSymbols: 4096, maximumScopes: 128, maximumInvocations: 256,
            maximumInvocationBindings: 4096, maximumDeclarations: 1024, maximumPrograms: 8192,
            maximumBindings: 8192, maximumFunctions: 64, maximumFunctionDepth: 32,
            maximumExpressionNodes: 4096, maximumExpressionDepth: 128, maximumCandidates: 1024,
            maximumCacheEntries: 8192, maximumEvaluationSteps: 2_000_000)
    }

    private func profile(sourceWidth: ExternalMOSNormalizationProfile.WidthConvention = .total,
        providerWidth: ExternalMOSNormalizationProfile.WidthConvention = .total,
        order: ExternalMOSNormalizationProfile.CandidateOrder = .unique,
        qualifiedWidth: Bool? = nil) async throws -> ExternalMOSNormalizationProfile {
        var entries: [(String, OSDIParameterKind, OSDIParameterType, [String])] = [
            ("l", .instance, .real, []), ("w", .instance, .real, []),
            ("nf", .instance, .real, []), ("m", .instance, .real, []), ("ad", .instance, .real, []),
            ("mode", .model, .integer, ["modealias"]), ("nmos", .model, .integer, []),
            ("pmos", .model, .integer, []), ("version", .model, .string, [])]
        if qualifiedWidth != nil {
            entries[1] = ("w", .instance, .real, ["instance.w"])
            entries.append(("w", .model, .real, ["model.w"]))
        }
        let parameters = try entries.enumerated().map { index, entry in
            try OSDIParameterInfo(index: index, names: [entry.0] + entry.3,
                kind: entry.1, type: entry.2, arrayLength: 0)
        }
        let descriptor = try OSDIDescriptorInfo(index: 0, name: "fixture-only", nodeCount: 4, terminalCount: 4,
            jacobianEntryCount: 16, stateCount: 0, collapsibleCount: 0, parameterCount: parameters.count,
            instanceParameterCount: 5, operatingPointCount: 0, noiseSourceCount: 0, instanceByteCount: 1, modelByteCount: 1)
        let artifact = try ArtifactReference(digest: .init(algorithm: .sha256,
            hexadecimalValue: String(repeating: "a", count: 64)), byteCount: 1,
            descriptor: .init(role: .input, kind: .model, format: .unknown))
        var rules: [ExternalMOSParameterRule] = [
            .init(sourceNames: ["l"], scope: .instance, providerName: "l", scale: .length, meaning: .length),
            .init(sourceNames: ["w"], scope: .instance, providerName: qualifiedWidth == true ? "instance.w" : "w", scale: .length, meaning: .width),
            .init(sourceNames: ["nf"], scope: .instance, providerName: "nf", scale: .none, meaning: .fingerCount),
            .init(sourceNames: ["m"], scope: .instance, providerName: "m", scale: .none, meaning: .multiplicity),
            .init(sourceNames: ["ad"], scope: .instance, providerName: "ad", scale: .area, meaning: .ordinary, nonnegative: true),
            .init(sourceNames: ["mode", "modealias"], scope: .model, providerName: "mode", scale: .none, meaning: .ordinary),
            .init(sourceNames: ["lmin"], scope: .model, providerName: nil, scale: .none, meaning: .lengthMinimum),
            .init(sourceNames: ["lmax"], scope: .model, providerName: nil, scale: .none, meaning: .lengthMaximum),
            .init(sourceNames: ["wmin"], scope: .model, providerName: nil, scale: .none, meaning: .widthMinimum),
            .init(sourceNames: ["wmax"], scope: .model, providerName: nil, scale: .none, meaning: .widthMaximum)]
        if qualifiedWidth != nil {
            rules.append(.init(sourceNames: ["mw"], scope: .model, providerName: "model.w", scale: .none, meaning: .ordinary))
        }
        return ExternalMOSNormalizationProfile(label: "fixture-only-no-physical-authority", artifact: artifact,
            descriptor: descriptor, parameters: parameters, sourceLevel: 54, sourceVersions: ["4.5", "4.5.0"], rules: rules,
            nmosAssignments: [try .init(name: "nmos", scope: .model, value: .integer(1))],
            pmosAssignments: [try .init(name: "pmos", scope: .model, value: .integer(1))], versionParameter: "version",
            sourceWidth: sourceWidth, selectionWidth: .sourceFlag, providerWidth: providerWidth,
            omittedFingerCount: 1, candidateOrder: order, duplicateModels: .reject, endpointToleranceSI: 0)
    }
}

private struct BinFixtureNoDependencyResolver: SPICEContextualFileResolver {
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        throw ParserDiagnostic.error("Unexpected dependency in external bin fixture")
    }
}

private final class ProfileResourceObserver: SPICESourceResourceAccounting {
    private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0 }
    private let state = Mutex(State())
    private let underlying: SPICESimulationResources
    init(maximumLiveBytes: UInt64 = 64_000_000) throws {
        underlying = try .init(maximumLiveBytes: maximumLiveBytes, maximumTemporaryBytes: 64_000_000,
            maximumWorkUnits: 10_000_000, maximumHashedBytes: 4_000_000)
    }
    var live: UInt64 { state.withLock { $0.live } }
    var temporary: UInt64 { state.withLock { $0.temporary } }
    func checkCancellation() throws { try underlying.checkCancellation() }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try underlying.charge(kind, units: units) }
    func chargeHashedBytes(_ bytes: UInt64) throws { try underlying.chargeHashedBytes(bytes) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        let held = try underlying.reserveStorage(kind: kind, byteCount: byteCount)
        state.withLock {
            if kind == .liveOwnedBytes { $0.live += byteCount } else { $0.temporary += byteCount }
        }
        return .init(kind: kind, byteCount: byteCount) { [self, held] in
            state.withLock {
                if kind == .liveOwnedBytes { $0.live -= byteCount } else { $0.temporary -= byteCount }
            }
            withExtendedLifetime(held) {}
        }
    }
}

private struct QuotaSourceProvider: SPICEExactSourceProviding {
    let source: SPICECheckedSource
    func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
        try work.checkCancellation()
        guard source.binding == binding else { throw MOSBinPreparationError.invalidSource("quota source") }
        return source
    }
}
