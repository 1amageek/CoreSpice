import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceOSDITestSupport
import CoreSpiceParsedIR
import OSDIRuntime
import Testing

struct OSDINativeFixture {
    let manifest: OSDIDCManifest
    let libraries: [OSDIDCManifest.Library]
    let directory: URL
    let references: [String: ArtifactReference]
    let provider: SPICEOSDILocalLibraryProvider
    let limits = SPICENativeExecutionLimits(maximumDeviceCount: 256, maximumMatrixDimension: 256,
        maximumAllocationBytes: 64 * 1024 * 1024)
    let numerical = TransientExecutionLimits(maximumAcceptedSteps: 1000, maximumSolveAttempts: 10000,
        maximumNewtonIterations: 100000, maximumSavedScalars: 100000, maximumMatrixDimension: 256,
        maximumWorkUnits: 1_000_000_000, maximumBreakpoints: 100)

    init(libraries: [OSDIDCManifest.Library]? = nil) throws {
        guard let path = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_MANIFEST"] else { throw OSDIDCManifest.Failure.invalidManifest }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        if libraries == nil {
            let profile = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_PROFILE"] ?? "latest-soi101-v1"
            try OSDIFamilyProfileAdmission.validate(bytes, profile: profile)
        }
        manifest = try JSONDecoder().decode(OSDIDCManifest.self, from: bytes)
        self.libraries = libraries ?? manifest.libraries
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-native-osdi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
        var references: [String: ArtifactReference] = [:], intents: [ArtifactAccessIntent] = []
        for library in self.libraries {
            let file = library.id + ".osdi"
            try FileManager.default.copyItem(atPath: library.path, toPath: directory.appendingPathComponent(file).path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: file), role: .input, kind: .model, format: .raw), relativeTo: directory)
            try #require(reference.digest.hexadecimalValue == library.sha256)
            references[library.id] = reference
            intents.append(try ArtifactAccessIntent(expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: rootID, relativePath: ArtifactRelativePath(segments: [file])), operation: .read,
                budget: ArtifactAccessBudget(maximumPageByteCount: 65536, maximumTotalByteCount: 64 * 1024 * 1024,
                    maximumPageCount: 4096, maximumWorkUnitCount: 10000, maximumDurationNanoseconds: 5_000_000_000)))
        }
        self.references = references
        provider = try SPICEOSDILocalLibraryProvider(rootID: rootID, directoryURL: directory, intents: intents,
            stagingParentDirectory: directory, digester: SHA256ContentDigester())
    }
    static func sourceName(_ original: String) -> String { ("N_" + original).lowercased() }
    func close() throws { try FileManager.default.removeItem(at: directory) }
    func runtime(_ point: OSDIDCManifest.Case, provider: (any OSDILibraryProviding)? = nil,
                 maximumAdapterBytes: UInt64 = 8 * 1024 * 1024) throws -> SPICEOSDIRuntimeInputs {
        try .init(provider: provider ?? self.provider,
            loadLimits: .init(maximumDescriptors: 16, maximumMetadataBytes: 4 * 1024 * 1024, maximumStorageBytes: 4 * 1024 * 1024),
            evaluationLimits: .init(maximumWorkspaceBytes: 8 * 1024 * 1024, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65536, maximumStringBytes: 65536), maximumInstanceCount: 16,
            maximumAdapterBytes: maximumAdapterBytes,
            tolerances: .init(temperatureAbsoluteKelvin: try #require(point.input.policy.unknownAbsoluteTolerances["K"]),
                thermalResidualAbsoluteWatts: try #require(point.input.policy.equationAbsoluteTolerances["W"])))
    }
    func catalog(_ point: OSDIDCManifest.Case) throws -> [String: OSDIResolvedInstance] {
        var result: [String: OSDIResolvedInstance] = [:]
        for device in point.input.devices {
            let library = try #require(libraries.first { $0.id == device.library })
            let parameters = try device.parameters.map { try $0.assignment() }
            let binding = try OSDIModelBinding(modelName: device.id, artifact: try #require(references[device.library]),
                descriptorIndex: device.descriptorIndex, expectedDescriptorName: library.descriptorName,
                modelParameters: parameters.filter { $0.scope == .model })
            result[Self.sourceName(device.id)] = try .init(binding: binding, instanceParameters: parameters.filter { $0.scope == .instance }, previousState: device.previousState)
        }
        return result
    }
    func input(_ point: OSDIDCManifest.Case, analysis: String = ".op",
               catalog: [String: OSDIResolvedInstance]? = nil) async throws -> PreparedSPICESimulation {
        var lines = ["OSDI native circuit \(point.id)"]
        for device in point.input.devices {
            let raw = try #require(point.reference.devices.first { $0.id == device.id }).rawNodes
            let terminals = try (0..<device.connectedTerminalCount).map { try #require(device.terminals[raw[$0].name]) }
            lines += [".model \(device.id) osdi", "\(Self.sourceName(device.id)) \(terminals.joined(separator: " ")) \(device.id)"]
        }
        for part in point.input.resistors { lines.append("\(part.id) \(part.positive) \(part.negative) \(part.value)") }
        for part in point.input.voltageSources { lines.append("\(part.id) \(part.positive) \(part.negative) \(part.value)") }
        for part in point.input.currentSources { lines.append("\(part.id) \(part.positive) \(part.negative) \(part.value)") }
        let policy = point.input.policy
        let ambient = try #require(point.input.devices.first).temperatureKelvin
        lines.append(".options temp=\(ambient - 273.15) tnom=27 gmin=0 reltol=\(policy.relativeTolerance) abstol=\(try #require(policy.equationAbsoluteTolerances["A"])) vntol=\(try #require(policy.equationAbsoluteTolerances["V"])) itl1=\(policy.maximumIterations)")
        for (name, value) in point.input.initialUnknowns.sorted(by: { $0.key < $1.key }) where name.hasPrefix("net:") {
            lines.append(".nodeset V(\(name.dropFirst(4)))=\(value)")
        }
        lines += [analysis, ".end"]
        return try await source(lines.joined(separator: "\n") + "\n", catalog: catalog ?? self.catalog(point))
    }
    func source(_ text: String, catalog: [String: OSDIResolvedInstance],
                resources suppliedResources: SPICESimulationResources? = nil) async throws -> PreparedSPICESimulation {
        let resources = try suppliedResources ?? SPICESimulationResources(maximumLiveBytes: 128 * 1024 * 1024,
            maximumTemporaryBytes: 128 * 1024 * 1024, maximumWorkUnits: 1_000_000_000, maximumHashedBytes: 64 * 1024 * 1024)
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "root", reference: try ArtifactReference(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let root = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 65536)
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "osdi-native-v1", configuration: configuration,
            resources: resources, maximumPageByteCount: 65536)
        let resolution = try MOSResolutionLimits(maximumRetainedBytes: 16 * 1024 * 1024, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 256, maximumScopes: 32, maximumInvocations: 64,
            maximumInvocationBindings: 512, maximumDeclarations: 128, maximumPrograms: 256, maximumBindings: 256,
            maximumFunctions: 32, maximumFunctionDepth: 32, maximumExpressionNodes: 256, maximumExpressionDepth: 128,
            maximumCandidates: 128, maximumCacheEntries: 256, maximumEvaluationSteps: 1_000_000)
        return try await SPICESimulationPreparer().prepare(.init(root: root, environment: environment,
            catalog: [binding], routes: [], provider: NoIncludes(), configuration: configuration, operatingPolicy: .recordActual,
            limits: .init(maximumElements: 2048, maximumTransformBytes: 32 * 1024 * 1024,
                maximumSweepPoints: 100, maximumPageByteCount: 65536, numerical: numerical),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: resolution, osdiInstances: catalog), resources: resources)
    }
    private struct NoIncludes: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource { throw SPICEExactSourceError.undeclaredSource(binding.key) }
    }
}
