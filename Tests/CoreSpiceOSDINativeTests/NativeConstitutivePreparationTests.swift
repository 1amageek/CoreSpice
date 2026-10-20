import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceAnalysis
import CoreSpiceParsedIR
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceEvent
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceOSDITestSupport
import Foundation
import OSDIContracts
import OSDIRuntime
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Actual exclusive Native constitutive preparation",
    .enabled(if: ProcessInfo.processInfo.environment["CORESPICE_OSDI_CONSTITUTIVE_ACTUAL_QUALIFICATION"] == "1",
        "Requires original source-bound model captures and qualified public operation-5 worker"),
    .timeLimit(.minutes(2)))
struct NativeConstitutivePreparationTests {
    private struct Pin: Decodable {
        let path: String
        let sha256: String
        let bytes: Int?
        func read() throws -> Data {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try #require(bytes == nil || bytes == data.count)
            try #require(NativeConstitutivePreparationTests.digest(data) == sha256, "Evidence changed: \(path)")
            return data
        }
    }
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let id, sourceFamily, program, setup, request, requestFormat: String
            let programSHA256, setupSHA256, requestSHA256: String
            let rawNodeCount, activeUnknownCount: Int
            let originalPointRequest, sourceInputManifest, priorCoverReceipt, priorQualification: Pin
        }
        let schema, baseSDKRevision: String
        let originalSourceInputPins: [Pin]
        let cases: [Entry]
    }
    private struct SourceManifest: Decodable {
        struct Family: Decodable {
            struct Context: Decodable { let timeHighBits, timeLowBits: UInt64 }
            let family, programSHA256, setupSHA256, requestSHA256, pointRequestSHA256: String
            let rawNodeCount, activeUnknownCount: Int
            let centerHighBits, centerLowBits: [UInt64]
            let context: Context
            let precisionBits: UInt32
        }
        let schema: String
        let controlBytes: Int
        let inputs: [Pin]
        let families: [Family]
    }
    private struct CoverReceipt: Decodable { let status: String; let exitCode: Int; let command: [String] }
    private struct CoverQualification: Decodable { let status: String; let receipts: [Pin] }
    private struct CProof: Decodable {
        struct Limits: Decodable {
            let coefficient_bits, arena_bytes, workspace_bytes, work, steps: UInt64
            let maximum_atoms, maximum_nodes: UInt32
        }
        struct Entry: Decodable {
            struct Result: Decodable {
                struct Identity: Decodable { let kind: UInt32; let rawRowCoefficients: [String] }
                let status, claimCount, rawRows, terminalCount: Int
                let identities: [Identity]
            }
            let id: String
            let inputs: [Pin]
            let result: Result
        }
        let schema: String
        let synthetic: String
        let rootFlowHistoryAuthority: Bool
        let limits: Limits
        let binary: Pin
        let actualCases: [Entry]
    }
    private struct PointRequest: Decodable {
        struct Model: Decodable {
            struct SimulationParameter: Decodable { let name: String; let value: OSDIDCManifest.Parameter.Value }
            struct Limits: Decodable {
                let maximumWorkspaceBytes, maximumDiagnosticBytes, maximumStringBytes: UInt64
                let maximumDiagnosticCount: UInt32
            }
            let libraryPath, expectedSHA256: String
            let expectedByteCount, descriptorIndex, connectedTerminalCount: Int
            let temperatureKelvin: Double
            let parameters: [OSDIDCManifest.Parameter]
            let simulationParameters: [SimulationParameter]
            let evaluationLimits: Limits
            static func scalar(_ value: OSDIDCManifest.Parameter.Value) throws -> OSDIParameterValue {
                switch value.kind {
                case "real": return .real(try #require(value.real))
                case "integer": return .integer(try #require(value.integer))
                case "string": return .string(try #require(value.string))
                default: throw OSDIDCManifest.Failure.invalidManifest
                }
            }
            func preparation() throws -> OSDIPreparationOptions {
                try OSDIPreparationOptions(parameters: parameters.map { try $0.assignment() },
                    simulationParameters: simulationParameters.map { try OSDISimulationParameter(name: $0.name, value: Self.scalar($0.value)) },
                    temperatureKelvin: temperatureKelvin, connectedTerminalCount: connectedTerminalCount,
                    limits: OSDIEvaluationLimits(maximumWorkspaceBytes: evaluationLimits.maximumWorkspaceBytes,
                        maximumDiagnosticCount: evaluationLimits.maximumDiagnosticCount,
                        maximumDiagnosticBytes: evaluationLimits.maximumDiagnosticBytes, maximumStringBytes: evaluationLimits.maximumStringBytes))
            }
        }
        let model: Model
        let semanticProfileSHA256: String
    }
    private static func environment(_ key: String) throws -> String {
        try #require(ProcessInfo.processInfo.environment[key], "Required qualification input: \(key)")
    }
    private static func digest(_ data: Data) throws -> String {
        try SHA256ContentDigester().digest(using: .sha256, limits: .singleBufferMaximum) { lease throws(ContentDigestError) in
            try lease.update(Array(data))
        }.digest.hexadecimalValue
    }
    private func compare(_ view: borrowing OSDIPrecisionConstitutiveEvaluationView,
        inventory: borrowing OSDIConstitutiveInventoryView, expected: CProof.Entry.Result,
        source: SourceManifest.Family, binding: OSDIPrecisionChartBinding) {
        let actualBinding = view.binding.source, coverBinding = view.cover.binding
        let claims = view.claimCount, leaves = view.cover.leafCount
        let raw = inventory.rawGlobal.count, active = inventory.activeGlobal.count
        let representatives = inventory.coordinateQuotient.representatives, bits = view.cover.usedPrecisionBits
        #expect(actualBinding == binding && coverBinding == binding)
        #expect(claims == expected.claimCount && leaves == expected.terminalCount && bits == source.precisionBits)
        #expect(raw == expected.rawRows && active == source.activeUnknownCount)
        #expect(representatives == (0..<active).map(UInt32.init))
        for index in 0..<active {
            let lh = view.cover.lowerHigh[index].bitPattern, ll = view.cover.lowerLow[index].bitPattern
            let uh = view.cover.upperHigh[index].bitPattern, ul = view.cover.upperLow[index].bitPattern
            let variable = inventory.activeVariables[index], global = inventory.activeGlobal[index]
            #expect(lh == source.centerHighBits[index] && uh == source.centerHighBits[index])
            #expect(ll == source.centerLowBits[index] && ul == source.centerLowBits[index])
            #expect(variable != nil && global != nil)
        }
        for row in 0..<raw {
            let index = inventory.rawActive[row], global = inventory.rawGlobal[row]
            if let index {
                let expectedGlobal = inventory.activeGlobal[index]
                #expect(global == expectedGlobal)
            } else { #expect(global == nil) }
        }
        guard claims == expected.identities.count else { return }
        for index in 0..<claims { view.withClaim(at: index) { claim in
            let kind = claim.kind.rawValue, rows = claim.rawRowCount, actual = claim.binding
            let reference = expected.identities[index]
            #expect(kind == reference.kind && rows == expected.rawRows && actual == view.binding)
            guard rows == reference.rawRowCoefficients.count else { return }
            for row in 0..<rows { claim.withCoefficient(at: row) { value in
                let scalar = reference.rawRowCoefficients[row]
                let power = value.denominatorPower, negative = value.negative, count = value.numeratorWords.count
                let word: UInt64? = count == 0 ? nil : value.numeratorWords[0]
                #expect(["-1", "0", "1"].contains(scalar) && power == 0)
                #expect(negative == (scalar == "-1"))
                if scalar == "0" { #expect(count == 0) }
                else { #expect(count == 1 && word == 1) }
            }}
        }}
    }

    private struct Fixture {
    struct Manifest: Decodable { let libraries: [Library] }
    typealias Library = OSDIDCManifest.Library
    let library: Library
    let directory: URL
    let reference: ArtifactReference
    let provider: Provider

    init(library: Library) throws {
        self.library = library
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-osdi-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: library.path, toPath: directory.appendingPathComponent("input.osdi").path)
        reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
            ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "input.osdi"), role: .input, kind: .model, format: .raw), relativeTo: directory)
        guard reference.digest.hexadecimalValue == library.sha256 else { throw FixtureFailure.digestMismatch }
        let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
        let root = try ArtifactRootCapability(rootID: rootID, directoryURL: directory, digester: SHA256ContentDigester())
        let intent = try ArtifactAccessIntent(expectedReference: reference,
            availability: .local(artifactID: reference.id, rootID: rootID, relativePath: ArtifactRelativePath(segments: ["input.osdi"])), operation: .read,
            budget: ArtifactAccessBudget(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
        provider = Provider(root: root, intent: intent, directory: directory)
    }
    func instance(_ name: String, nodes: [Node], parameters: [OSDIParameterAssignment] = [], modelParameters: [OSDIParameterAssignment] = [],
                  previousState: [Double] = []) throws -> Instance {
        let binding = try OSDIModelBinding(modelName: "model", artifact: reference, descriptorIndex: library.descriptorIndex,
            expectedDescriptorName: library.descriptorName, modelParameters: modelParameters)
        let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: parameters, previousState: previousState)
        return Instance(name: name, typeName: "osdi", nodes: nodes, parameters: [:], osdi: .resolved(resolved))
    }
    func close() async throws {
        try await provider.root.close().wait()
        try FileManager.default.removeItem(at: directory)
    }
    struct Provider: OSDILibraryProviding {
        let root: ArtifactRootCapability
        let intent: ArtifactAccessIntent
        let directory: URL
        func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
            guard reference == intent.expectedReference else { throw .identityMismatch }
            return try await OSDINativeLibraryLoader(stagingParentDirectory: directory).load(intent, source: root, limits: limits)
        }
    }
    enum FixtureFailure: Error { case missingManifest, missingDescriptor, digestMismatch, missingOwner }
    }
    private struct Qualification {
    enum Refusal: Error, Equatable { case invalidBinding }
    private struct Pin: Decodable {
        let path: String
        let sha256: String
        func read() throws -> Data {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard try Qualification.digest(bytes) == sha256 else { throw Refusal.invalidBinding }
            return bytes
        }
    }
    private struct PublicReceipt: Decodable {
        struct Precision: Decodable {
            let numericProfileSHA256, workerSHA256: String
            let workerReceipt: Pin
        }
        struct Source: Decodable { let revision, version: String }
        struct Resolution: Decodable { let mode: String; let overrideCount: Int }
        let status: String
        let precision: Precision
        let source: Source
        let dependencyResolution: Resolution
    }
    private struct WorkerReceipt: Decodable {
        let schema: Int
        let worker, numericProfile: Pin
    }
    private struct NumericProfile: Decodable {
        struct Worker: Decodable { let sha256: String }
        let schema: Int
        let worker: Worker
    }
    let numericProfileSHA256: String
    let workerSHA256: String

    private static func environment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { throw Refusal.invalidBinding }
        return value
    }
    private static func digest(_ bytes: Data) throws -> String {
        try SHA256ContentDigester().digest(using: .sha256, limits: .singleBufferMaximum) { lease throws(ContentDigestError) in
            try lease.update(Array(bytes))
        }.digest.hexadecimalValue
    }
    static func load(expectedNumericProfile: String? = nil, runtimeWorkerPath: String? = nil) throws -> Self {
        let profileSHA = try expectedNumericProfile ?? environment("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")
        let workerSHA = try environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER_SHA256")
        let decoder = JSONDecoder()
        let qualification = try decoder.decode(PublicReceipt.self, from: Pin(
            path: environment("CORESPICE_OSDI_CONSTITUTIVE_QUALIFICATION_RECEIPT"),
            sha256: environment("CORESPICE_OSDI_CONSTITUTIVE_QUALIFICATION_RECEIPT_SHA256")).read())
        guard qualification.status == "passed", qualification.source.version == "1.2.0",
              qualification.source.revision == "e17d3bcca1224c8ab9ccfaddea7a47580b29b748",
              qualification.dependencyResolution.mode == "public-remote-no-overrides",
              qualification.dependencyResolution.overrideCount == 0,
              qualification.precision.numericProfileSHA256 == profileSHA,
              qualification.precision.workerSHA256 == workerSHA else { throw Refusal.invalidBinding }
        let built = try decoder.decode(WorkerReceipt.self, from: qualification.precision.workerReceipt.read())
        guard built.schema == 1, built.worker.sha256 == workerSHA,
              built.numericProfile.sha256 == profileSHA else { throw Refusal.invalidBinding }
        let profile = try decoder.decode(NumericProfile.self, from: built.numericProfile.read())
        guard profile.schema == 1, profile.worker.sha256 == workerSHA else { throw Refusal.invalidBinding }
        // Verify both the qualified build output and the exact runtime worker path.
        _ = try built.worker.read()
        let workerPath = try runtimeWorkerPath ?? environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER")
        _ = try Pin(path: workerPath, sha256: workerSHA).read()
        return Self(numericProfileSHA256: profileSHA, workerSHA256: workerSHA)
    }
    }
    private var nativeLimits: SPICENativeExecutionLimits {
        .init(maximumDeviceCount: 256, maximumMatrixDimension: 256, maximumAllocationBytes: 4_294_967_296)
    }
    private var numericalLimits: TransientExecutionLimits {
        .init(maximumAcceptedSteps: 1000, maximumSolveAttempts: 10000, maximumNewtonIterations: 100000,
            maximumSavedScalars: 100000, maximumMatrixDimension: 256, maximumWorkUnits: 8_000_000_000,
            maximumBreakpoints: 100)
    }
    private final class Resources: SPICESourceResourceAccounting {
        enum Refusal: Error { case expected, work, storage, cancelled }
        struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var reservations = 0; var releases = 0
            var workLimit: UInt64 = 8_000_000_000
            var refuseStorage = false; var cancelled = false
            var onReserve: (@Sendable () throws -> Void)?
        }
        private let state = Mutex(State())
        private let base: SPICESimulationResources
        init() throws {
            base = try SPICESimulationResources(maximumLiveBytes: 8_589_934_592,
                maximumTemporaryBytes: 8_589_934_592, maximumWorkUnits: 8_000_000_000,
                maximumHashedBytes: 1_073_741_824)
        }
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var work: UInt64 { state.withLock { $0.work } }
        var reservations: Int { state.withLock { $0.reservations } }
        var releases: Int { state.withLock { $0.releases } }
        func limitWork(_ value: UInt64) { state.withLock { $0.workLimit = value } }
        func refuseStorage(_ value: Bool) { state.withLock { $0.refuseStorage = value } }
        func cancel(_ value: Bool) { state.withLock { $0.cancelled = value } }
        func onReserve(_ body: (@Sendable () throws -> Void)?) { state.withLock { $0.onReserve = body } }
        func checkCancellation() throws {
            if state.withLock({ $0.cancelled }) { throw Refusal.cancelled }
            try base.checkCancellation()
        }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                guard value.work <= value.workLimit, units <= value.workLimit - value.work else { throw Refusal.work }
                value.work += units
            }
            try base.charge(kind, units: units)
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try base.chargeHashedBytes(bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            let callback = try state.withLock { value in
                if value.refuseStorage { throw Refusal.storage }
                return value.onReserve
            }
            try callback?()
            let original = try base.reserveStorage(kind: kind, byteCount: byteCount)
            state.withLock { value in
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
                value.reservations += 1
            }
            return SPICESourceStorageReservation(kind: kind, byteCount: byteCount) { [self, original] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                    value.releases += 1
                }
                withExtendedLifetime(original) {}
            }
        }
    }
    private func withSimple(count: Int = 1, nativeParts: Bool = false, point: Bool = false,
        maximumAdapterBytes: UInt64 = 16_777_216,
        _ body: (Fixture, CircuitIR, SPICEOSDIRuntimeInputs, NativeConstitutivePreparationInputs,
            OSDIConstitutiveCaptureInputs) async throws -> Void) async throws {
        _ = try Qualification.load()
        let fixture = try Fixture(library: .init(id: "public-source", path: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_MODEL"),
            sha256: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_MODEL_SHA256"), descriptorIndex: 0,
            descriptorName: "public_precision_source"))
        do {
            let workerURL = fixture.directory.appendingPathComponent("worker")
            try FileManager.default.copyItem(atPath: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER"), toPath: workerURL.path)
            let worker = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "worker"), role: .input, kind: .model, format: .raw),
                relativeTo: fixture.directory)
            let expectedWorker = try Self.environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER_SHA256")
            try #require(worker.digest.hexadecimalValue == expectedWorker)
            let intent = try ArtifactAccessIntent(expectedReference: worker,
                availability: .local(artifactID: worker.id, rootID: fixture.provider.root.rootID,
                    relativePath: ArtifactRelativePath(segments: ["worker"])), operation: .read,
                budget: ArtifactAccessBudget(maximumPageByteCount: 65536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            let policy = try OSDIPrecisionOptions(maximumProgramBytes: 1_048_576, maximumMappingBytes: 16_777_216,
                arenaBytes: 16_777_216, maximumWorkUnits: 100_000_000, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
                startupTimeoutNanoseconds: 2_000_000_000, evaluationTimeoutNanoseconds: 2_000_000_000,
                cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
            let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
            let snapshot = NativeConstitutivePreparationInputs(preparer: factory,
                semanticProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_MODEL_SEMANTIC_SHA256")), options: policy)
            let capture = try OSDIConstitutiveCaptureInputs(preparer: factory, evaluator: OSDINativePrecisionEvaluator(),
                worker: intent, source: fixture.provider.root,
                numericProfile: ContentDigest(algorithm: .sha256, hexadecimalValue: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")),
                options: policy,
                coverLimits: OSDIPrecisionDecisionCoverLimits(maximumSteps: 100_000, maximumGuardRecords: 100_000,
                    maximumCopiedBytes: 10_000_000, maximumCells: 100, maximumNodes: 256, maximumLeaves: 64,
                    maximumPending: 256, maximumDepth: 256, maximumIntegerBits: 1025),
                limits: OSDIPrecisionConstitutiveLimits(maximumNodes: 256, maximumAtoms: 64,
                    maximumCoefficientBits: 4096, maximumWorkspaceBytes: 2_097_152))
            let node = Node(id: 1), branch = Branch(id: 0)
            var instances = try (0..<count).map { try fixture.instance("N\($0)", nodes: [node]) }
            if nativeParts {
                instances.append(Instance(name: "R1", typeName: "resistor", nodes: [node, .ground], parameters: ["r": .real(1000)]))
                instances.append(Instance(name: "C1", typeName: "capacitor", nodes: [node, .ground], parameters: ["c": .real(1e-6)]))
                instances.append(Instance(name: "V1", typeName: "vsource", nodes: [node, .ground], parameters: ["v": .real(0)], ownedBranches: [branch]))
            }
            let ir = CircuitIR(nodes: [.ground, node], branches: nativeParts ? [branch] : [], instances: instances)
            let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
                loadLimits: .init(maximumDescriptors: 16, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
                evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 64,
                    maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: count,
                maximumAdapterBytes: maximumAdapterBytes,
                tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12),
                transientPrecision: point ? OSDITransientPrecisionInputs(preparer: factory,
                    worker: intent, source: fixture.provider.root, semanticProfile: snapshot.semanticProfile,
                    numericProfile: capture.numericProfile, options: policy, precisionBits: 192) : nil)
            try await body(fixture, ir, runtime, snapshot, capture)
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }
    private func prepare(_ ir: CircuitIR, runtime: SPICEOSDIRuntimeInputs,
        snapshot: NativeConstitutivePreparationInputs, resources: Resources,
        cancellation: CancellationToken = .init()) async throws -> PreparedNativeCircuit {
        let preparer: any NativeConstitutiveCircuitPreparing = NativeCircuitPreparer()
        return try await preparer.prepare(ir: ir, registry: .standard(), operatingConditions: .nominal,
            limits: nativeLimits, numericalLimits: numericalLimits, resources: resources,
            osdi: runtime, constitutive: snapshot, cancellation: cancellation)
    }
    private func observe(_ capture: inout OSDIConstitutiveCapture) throws -> OSDIConstitutiveCaptureRetention {
        let lo = [-1.0], hi = [1.0], zero = [0.0]
        let time = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return try capture.withCheckedIdentities(lowerHigh: lo.span, lowerLow: zero.span, upperHigh: hi.span, upperLow: zero.span,
            lowerContext: time, upperContext: time, precisionBits: 192) { view, inventory in
                let rows = inventory.rawGlobal.count, leaves = view.cover.leafCount, claims = view.claimCount
                #expect(rows == 1 && leaves > 0 && claims > 0)
                let retention = inventory.retention
                return try #require(retention)
            }
    }
    private struct CopiedClaim: Sendable {
        let retention: OSDIConstitutiveCaptureRetention
        let negative: Bool
        let power: UInt64
        let words: [UInt64]
        let storage: SPICESourceStorageReservation
    }
    private func copyFirstClaim(_ capture: inout OSDIConstitutiveCapture,
        control: NativeConstitutivePreparationControl) throws -> CopiedClaim {
        let lo = [-1.0], hi = [1.0], zero = [0.0]
        let time = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return try capture.withCheckedIdentities(lowerHigh: lo.span, lowerLow: zero.span, upperHigh: hi.span, upperLow: zero.span,
            lowerContext: time, upperContext: time, precisionBits: 192) { view, inventory in
                let claims = view.claimCount, retained = inventory.retention
                try #require(claims > 0)
                let retention = try #require(retained)
                let result: Swift.Result<CopiedClaim, any Error> = view.withClaim(at: 0) { claim in
                    let rows = claim.rawRowCount
                    #expect(rows == 1)
                    return claim.withCoefficient(at: 0) { value in
                        do {
                            let count = value.numeratorWords.count, negative = value.negative, power = value.denominatorPower
                            try #require(count == 1)
                            let bytes = UInt64(count * MemoryLayout<UInt64>.stride + MemoryLayout<[UInt64]>.stride + MemoryLayout<CopiedClaim>.stride)
                            let storage = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: bytes)
                            try control.checkpoint(workUnits: count * 2)
                            var words = [UInt64](repeating: 0, count: count)
                            for i in 0..<count { words[i] = value.numeratorWords[i] }
                            return .success(CopiedClaim(retention: retention, negative: negative, power: power, words: words, storage: storage))
                        } catch { return .failure(error) }
                    }
                }
                return try result.get()
            }
    }
    @Test func originalFloorSurvivesOldLeaseReleaseAndSourceFailureRollsBack() throws {
        let resources = try Resources()
        do {
            let control = try NativeConstitutivePreparationControl.make(resources: resources,
                maximumBytes: 4096, ordinaryFloor: 100, cancellation: .init())
            let initial = resources.live + resources.temporary
            resources.refuseStorage(true)
            do { _ = try control.reserveStorage(byteCount: 100); Issue.record("Refused source lease admitted") }
            catch Resources.Refusal.storage {}
            resources.refuseStorage(false)
            #expect(resources.live + resources.temporary == initial)
            var old: (any Sendable)? = try control.reserveStorage(byteCount: 200)
            let floor = try control.seal(retainedOrdinaryFloor: 100)
            #expect(floor == 100 + resources.live + resources.temporary)
            let before = resources.live + resources.temporary
            var current: (any Sendable)? = try control.reserveStorage(byteCount: 200)
            let delta = resources.live + resources.temporary - before
            withExtendedLifetime(old) {}; old = nil
            let count = resources.reservations
            do {
                _ = try control.reserveStorage(byteCount: Int(4096 - floor - delta + 1))
                Issue.record("Released old snapshot weakened the sealed floor")
            } catch NativeConstitutivePreparationControl.Failure.capacityExceeded {}
            #expect(resources.reservations == count)
            withExtendedLifetime(current) {}; current = nil
            _ = try control.reserveStorage(byteCount: 1)
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func pendingAdmissionRejectsReentrantSealAndFloorChanges() throws {
        let resources = try Resources()
        do {
            let control = try NativeConstitutivePreparationControl.make(resources: resources,
                maximumBytes: 4096, ordinaryFloor: 100, cancellation: .init())
            let calls = CallCount()
            resources.onReserve {
                do { _ = try control.seal(retainedOrdinaryFloor: 100); Issue.record("Pending ticket sealed") }
                catch NativeConstitutivePreparationControl.Failure.busy { calls.state.withLock { $0 += 1 } }
                do { try control.setPreparingFloor(50); Issue.record("Pending ticket changed floor") }
                catch NativeConstitutivePreparationControl.Failure.busy { calls.state.withLock { $0 += 1 } }
            }
            defer { resources.onReserve(nil) }
            let lease = try control.reserveStorage(byteCount: 10)
            resources.onReserve(nil)
            #expect(calls.state.withLock { $0 } == 2)
            _ = try control.seal(retainedOrdinaryFloor: 100)
            withExtendedLifetime(lease) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func actualNativeRCVJoinAndRetainedClaimKeepOriginalAdmissionAfterClose() async throws {
        let resources = try Resources()
        var retained: CopiedClaim?
        var evidence: NativeCircuitPreparationRecord?
        try await withSimple(nativeParts: true) { _, ir, runtime, snapshot, inputs in
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            let initialFloor = owner.record.compileCapacity
            var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
            do {
                retained = try copyFirstClaim(&capture, control: #require(owner.record.constitutiveBacking).control)
                _ = try observe(&capture)
            } catch { try capture.close(); try owner.close(); throw error }
            try capture.close()
            evidence = try owner.record.valueEvidence()
            try owner.close()
            #expect(evidence?.compileCapacity == initialFloor)
            #expect(evidence?.constitutiveBacking?.programs.count == 1)
            #expect(evidence?.osdiLifetime == nil)
        }
        #expect(resources.live + resources.temporary > 0)
        withExtendedLifetime(evidence) {}; evidence = nil
        #expect(resources.live + resources.temporary > 0)
        if let identity = retained {
            #expect(identity.words == [1] && identity.power == 0 && !identity.negative)
            identity.retention.withInventory { inventory in
                let raw = inventory.rawGlobal.count, dimension = inventory.matrixDimension
                #expect(raw == 1 && dimension == 2)
            }
            withExtendedLifetime(identity) {}
        } else { Issue.record("Missing copied claim retention") }
        withExtendedLifetime(retained) {}; retained = nil
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func ordinaryNativePreparationCannotOpenAConstitutiveCapture() async throws {
        let resources = try Resources()
        try await withSimple { _, ir, runtime, _, inputs in
            let owner = try await NativeCircuitPreparer().prepare(ir: ir, registry: .standard(), operatingConditions: .nominal,
                limits: nativeLimits, numericalLimits: numericalLimits, resources: resources, osdi: runtime)
            do {
                #expect(owner.record.constitutiveBacking == nil)
                do {
                    var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                    try capture.close(); Issue.record("Ordinary owner fabricated snapshot authority")
                } catch OSDIConstitutiveCaptureFailure.missingSnapshot {}
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    private final class CallCount: Sendable {
        let state = Mutex(0)
    }
    private struct Wrapped: BoundDevice, OSDIConstitutiveCapturePreparing {
        let underlying: any BoundDevice
        let called: CallCount
        var instance: Instance { underlying.instance }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try underlying.stampDC(into: &stamper, state: state) }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
            try underlying.stampAC(into: &stamper, state: state, omega: omega)
        }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
            try underlying.stampTransient(into: &stamper, state: state, integration: integration)
        }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
            underlying.checkConvergence(state: state, previousState: previousState)
        }
        func prepareConstitutiveCapture(inputs: OSDIConstitutiveCaptureInputs) async throws -> OSDIConstitutiveCapture {
            called.state.withLock { $0 += 1 }; throw OSDIConstitutiveCaptureFailure.invalidBinding
        }
    }

    @Test(arguments: [0, 1]) func completeInspectionRejectsCustomForeignAndNativeProducers(replaced: Int) async throws {
        let resources = try Resources()
        try await withSimple(nativeParts: true) { _, ir, runtime, snapshot, inputs in
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            let (record, original) = owner.takeState()
            var devices = original
            let called = CallCount()
            devices[replaced] = Wrapped(underlying: original[replaced], called: called)
            let forged = PreparedNativeCircuit(record: record, devices: devices)
            do {
                do {
                    var capture = try await forged.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                    try capture.close(); Issue.record("Protocol/name-only producer admitted")
                } catch OSDIConstitutiveCaptureFailure.invalidBinding { #expect(replaced == 0) }
                catch NativeConstitutiveInspection.Failure.unsupportedProducer(let name) { #expect(replaced == 1 && name == "R1") }
                #expect(called.state.withLock { $0 } == 0)
            } catch { try forged.close(); throw error }
            try forged.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func nativeSnapshotCapacityRefusesBeforeUnadmittedConstructionAndCloses() async throws {
        let resources = try Resources()
        try await withSimple { _, ir, runtime, snapshot, _ in
            let ordinary = runtime.loadLimits.maximumMetadataBytes + runtime.loadLimits.maximumStorageBytes
                + runtime.evaluationLimits.maximumWorkspaceBytes + runtime.maximumAdapterBytes
            let ceiling = ordinary + NativeConstitutivePreparationControl.logicalStateBytes + 1
            do {
                let preparer: any NativeConstitutiveCircuitPreparing = NativeCircuitPreparer()
                let owner = try await preparer.prepare(ir: ir, registry: .standard(), operatingConditions: .nominal,
                    limits: .init(maximumDeviceCount: 256, maximumMatrixDimension: 256, maximumAllocationBytes: ceiling),
                    numericalLimits: numericalLimits, resources: resources, osdi: runtime, constitutive: snapshot,
                    cancellation: .init())
                try owner.close(); Issue.record("Snapshot exceeded Native admission")
            } catch SPICENativePreparationError.osdi(.runtime(.host(_, let cause))) {
                guard case NativeConstitutivePreparationControl.Failure.capacityExceeded = cause else { throw cause }
            }
            #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
        }
    }

    @Test(arguments: [false, true])
    func oneSourceWorkOwnerCoversBothInstancesAndEveryCapture(point: Bool) async throws {
        let resources = try Resources()
        try await withSimple(count: 2, point: point) { _, ir, runtime, snapshot, inputs in
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            do {
                let baseline = resources.work
                resources.limitWork(baseline + 2 * inputs.options.maximumWorkUnits - 1)
                var first = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                _ = try observe(&first)
                let charged = resources.work
                try first.close()
                #expect(resources.work == charged && charged >= baseline + inputs.options.maximumWorkUnits)
                let bytes = resources.live + resources.temporary
                do {
                    var second = try await owner.prepareConstitutiveCapture(at: 1, inputs: inputs, cancellation: .init())
                    try second.close(); Issue.record("Second instance reset the invocation allowance")
                } catch Resources.Refusal.work {}
                #expect(resources.live + resources.temporary == bytes)
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func nativeNumericalStorageAndCaptureShareRemainingHeadroom() async throws {
        let resources = try Resources()
        try await withSimple { _, ir, runtime, snapshot, inputs in
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            do {
                let storage = try NativeExecutionStorage(preparation: owner.record, scalars: 0, retainedBytes: 0)
                var occupied: NativeExecutionStorage.MaterializationLease? = try storage.reserveMaterializationBytes(
                    nativeLimits.maximumAllocationBytes - owner.record.compileCapacity - 1_048_576)
                let bytes = resources.live + resources.temporary
                do {
                    var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                    try capture.close(); Issue.record("Capture ignored concurrent numerical storage")
                } catch NativeConstitutivePreparationControl.Failure.capacityExceeded {}
                #expect(resources.live + resources.temporary == bytes)
                withExtendedLifetime(occupied) {}; occupied = nil
                var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                _ = try observe(&capture)
                try capture.close()
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func cancellationAndSourceStorageRefusalPreserveOwnerAndRefund() async throws {
        let resources = try Resources()
        try await withSimple { _, ir, runtime, snapshot, inputs in
            let cancelled = CancellationToken(); cancelled.cancel()
            do {
                let rejected = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources, cancellation: cancelled)
                try rejected.close(); Issue.record("Cancelled Native preparation succeeded")
            } catch SPICENativePreparationError.resource(let cause) {
                guard case NativeConstitutivePreparationControl.Failure.cancelled = cause else { throw cause }
            }
            #expect(resources.live == 0 && resources.temporary == 0)
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            do {
                let baseline = resources.live + resources.temporary
                resources.refuseStorage(true)
                do {
                    var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                    try capture.close(); Issue.record("Source storage refusal ignored")
                } catch Resources.Refusal.storage {}
                resources.refuseStorage(false)
                #expect(resources.live + resources.temporary == baseline)
                resources.cancel(true)
                do {
                    var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                    try capture.close(); Issue.record("Source cancellation ignored")
                } catch Resources.Refusal.cancelled {}
                resources.cancel(false)
                #expect(resources.live + resources.temporary == baseline)
                var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                _ = try observe(&capture); try capture.close()
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    private func source(_ text: String, catalog: [String: OSDIResolvedInstance],
                resources: any SPICESourceResourceAccounting) async throws -> PreparedSPICESimulation {
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
                maximumSweepPoints: 100, maximumPageByteCount: 65536, numerical: numericalLimits),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: resolution, osdiInstances: catalog), resources: resources)
    }
    private struct NoIncludes: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource { throw SPICEExactSourceError.undeclaredSource(binding.key) }
    }

    @Test(arguments: [UInt64(16_777_216), UInt64(1_073_741_824)])
    func actualSPICEFinishAndSourceBindingPreadmitTheirOwnedStorage(maximumAdapterBytes: UInt64) async throws {
        let resources = try Resources()
        // The small controlled profile refuses the fresh ordinary binder's P/U allowance;
        // the existing actual-model profile admits it without changing either capacity rule.
        try await withSimple(point: true, maximumAdapterBytes: maximumAdapterBytes) { fixture, _, runtime, snapshot, inputs in
            let instance = try fixture.instance("n0", nodes: [Node(id: 1)])
            let resolved = try #require(instance.osdi?.resolved)
            let input = try await source("""
                Controlled Native source preparation
                .model model osdi
                N0 out model
                R1 out 0 1k
                V1 out 0 0
                .tran 1n 2n
                .end
                """, catalog: ["n0": resolved], resources: resources)
            let sourceBytes = resources.live + resources.temporary
            let factory: any NativeConstitutiveSPICEPreparing = SPICENativeSimulation()
            let owner = try await factory.prepare(input, limits: nativeLimits, osdi: runtime,
                constitutive: snapshot, cancellation: .init())
            do {
                let common = owner.record.circuitPreparation
                let facts = try #require(owner.record.precisionConfigurationFacts)
                let saved = try #require(common.constitutiveBacking?.programs.first)
                let model = try #require(facts.coldModels.first)
                #expect(facts.coldModels.count == 1 && facts.sourceInputIdentity == input.sourceInputIdentity)
                #expect(model.programDigest == saved.programDigest && model.setupDigest == saved.setupDigest)
                #expect(model.programByteCount == UInt64(saved.programByteCount)
                    && model.setupByteCount == UInt64(saved.setupByteCount))
                #expect(common.compileCapacity > sourceBytes && common.compileCapacity <= resources.live + resources.temporary)
                let retainedBytes = try NativePrecisionConfigurationFacts.metadataByteCount(input: input, common: common)
                let receipt = try #require(common.reservations.last)
                #expect(receipt.kind == .liveOwnedBytes && receipt.byteCount == retainedBytes)
                var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                _ = try observe(&capture); try capture.close()

                let baselineBytes = resources.live + resources.temporary
                do {
                    let binder = try NativeSourceCircuitDeviceBinding(input: input, limits: nativeLimits,
                        maximumReexecutions: 1, cancellation: .init(), baselinePreparation: common)
                    #expect(resources.live + resources.temporary > baselineBytes)
                    if maximumAdapterBytes == 16_777_216 {
                        do {
                            _ = try await binder.bind(plan: owner.plan, instances: owner.plan.ir.instances, cancellation: .init())
                            Issue.record("Fresh ordinary point exceeded its explicit adapter ceiling")
                        } catch SPICENativePreparationError.osdi(.capacityExceeded) {}
                    } else {
                        do {
                            let child = try await binder.bind(plan: owner.plan, instances: owner.plan.ir.instances, cancellation: .init())
                            let analysis = try binder.configureDCAnalysis(DCAnalysis(config: input.configuration.options.convergence),
                                plan: child.plan, devices: child.devices, cancellation: .init())
                            let result = try await analysis.run(circuit: child, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                            let voltage = try result.voltage(at: Node(id: 1))
                            #expect(voltage == 0)
                            withExtendedLifetime(child) {}
                        } catch { throw binder.failure(error, closing: common) }
                    }
                }
                #expect(resources.live + resources.temporary == baselineBytes)
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func retainedFloorGrowthCannotBeBypassedByAnOlderRecordAndRollsBackRefusal() async throws {
        let resources = try Resources()
        try await withSimple(point: true) { _, ir, runtime, snapshot, _ in
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            do {
                let old = owner.record
                let storage = try NativeExecutionStorage(preparation: old, scalars: 0, retainedBytes: 0)
                let before = resources.live + resources.temporary
                resources.refuseStorage(true)
                do {
                    _ = try old.reservingRetainedStorage(byteCount: 4096)
                    Issue.record("Source refusal committed retained floor")
                } catch Resources.Refusal.storage {}
                resources.refuseStorage(false)
                #expect(resources.live + resources.temporary == before)
                resources.cancel(true)
                do {
                    _ = try old.reservingRetainedStorage(byteCount: 4096)
                    Issue.record("Cancellation committed retained floor")
                } catch Resources.Refusal.cancelled {}
                resources.cancel(false)
                #expect(resources.live + resources.temporary == before)
                let grown = try old.reservingRetainedStorage(byteCount: 4096)
                #expect(grown.compileCapacity > old.compileCapacity + 4096)
                let occupied = try storage.reserveMaterializationBytes(nativeLimits.maximumAllocationBytes - grown.compileCapacity - 4096)
                let reservations = resources.reservations
                do {
                    _ = try storage.reserveMaterializationBytes(4096)
                    Issue.record("Old record bypassed current floor and ticket metadata")
                } catch SPICENativeExecutionError.resource(let cause) {
                    guard case NativeConstitutivePreparationControl.Failure.capacityExceeded = cause else { throw cause }
                }
                #expect(resources.reservations == reservations)
                withExtendedLifetime(occupied) {}
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    private final class CancelBeforeCaptureReturn: OSDIPrecisionConstitutiveSessionPreparing {
        let native: OSDINativePrecisionSessionPreparer
        let cancellation: CancellationToken
        let hideDirectory: Bool
        private let held = Mutex<(original: URL, moved: URL)?>(nil)
        init(directory: URL, cancellation: CancellationToken, hideDirectory: Bool) {
            native = .init(stagingParentDirectory: directory)
            self.cancellation = cancellation; self.hideDirectory = hideDirectory
        }
        func prepareConstitutiveIdentities(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent,
            source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions,
            coverLimits: OSDIPrecisionDecisionCoverLimits, limits: OSDIPrecisionConstitutiveLimits,
            coordinateQuotient: OSDIPrecisionCoordinateQuotient) async throws(OSDIPrecisionConstitutiveError) -> OSDIPrecisionSession {
            let directory = native.stagingParentDirectory
            let before: Set<URL>
            do { before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) }
            catch { throw .runtime(.host(operation: "capture cancellation fixture", underlying: error)) }
            var session = try await native.prepareConstitutiveIdentities(program: program, worker: worker, source: source,
                numericProfile: numericProfile, options: options, coverLimits: coverLimits, limits: limits,
                coordinateQuotient: coordinateQuotient)
            do {
                if hideDirectory {
                    let after = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
                    let added = after.subtracting(before)
                    try #require(added.count == 1)
                    let original = try #require(added.first)
                    let moved = directory.appendingPathComponent("cancelled-held-helper")
                    try FileManager.default.moveItem(at: original, to: moved)
                    held.withLock { $0 = (original, moved) }
                }
                cancellation.cancel()
                return consume session
            } catch {
                let failure = OSDIError.host(operation: "capture cancellation fixture", underlying: error)
                do { try session.close() }
                catch { throw .cleanup(primary: .runtime(failure), secondary: error) }
                throw .runtime(failure)
            }
        }
        func restoreDirectory() throws {
            let pair = held.withLock { value in let result = value; value = nil; return result }
            if let pair { try FileManager.default.moveItem(at: pair.moved, to: pair.original) }
        }
    }
    private func cancellingInputs(_ inputs: OSDIConstitutiveCaptureInputs,
        preparer: CancelBeforeCaptureReturn) -> OSDIConstitutiveCaptureInputs {
        .init(preparer: preparer, evaluator: inputs.evaluator, worker: inputs.worker, source: inputs.source,
            numericProfile: inputs.numericProfile, options: inputs.options, coverLimits: inputs.coverLimits, limits: inputs.limits)
    }

    @Test(arguments: [false, true])
    func distinctCallCancellationAfterGenuineStartupClosesOrRetainsRetryAuthority(hideDirectory: Bool) async throws {
        let resources = try Resources()
        try await withSimple(point: true) { fixture, ir, runtime, snapshot, inputs in
            let request = CancellationToken(), call = CancellationToken()
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources, cancellation: request)
            do {
                let baseline = resources.live + resources.temporary
                let factory = CancelBeforeCaptureReturn(directory: fixture.directory, cancellation: call, hideDirectory: hideDirectory)
                var pending: OSDIConstitutiveCaptureCleanup?
                do {
                    var capture = try await owner.prepareConstitutiveCapture(at: 0,
                        inputs: cancellingInputs(inputs, preparer: factory), cancellation: call)
                    try capture.close(); Issue.record("Cancelled call published a genuine capture")
                } catch NativeConstitutiveInspection.Failure.cancelled { #expect(!hideDirectory) }
                catch OSDIConstitutiveCaptureFailure.cleanupPending(let primary, let secondary, let cleanup) {
                    #expect(hideDirectory && secondary != nil)
                    guard case .cleanup(primary: .control(let cancellation), secondary: _) = primary,
                          case NativeConstitutiveInspection.Failure.cancelled = cancellation else { throw primary }
                    pending = cleanup
                }
                #expect(call.isCancelled && !request.isCancelled)
                if hideDirectory {
                    #expect(pending != nil && resources.live + resources.temporary > baseline)
                    try factory.restoreDirectory()
                    try pending?.close(); try pending?.close(); pending = nil
                }
                #expect(resources.live + resources.temporary == baseline)
                var reused = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                _ = try observe(&reused); try reused.close()
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func actualSPICEDelegationRefusesDistinctTokenCancelledDuringStartup() async throws {
        let resources = try Resources()
        try await withSimple(point: true) { fixture, _, runtime, snapshot, inputs in
            let resolved = try #require(try fixture.instance("n0", nodes: [Node(id: 1)]).osdi?.resolved)
            let input = try await source("Controlled cancellation\n.model model osdi\nN0 out model\n.tran 1n 2n\n.end\n",
                catalog: ["n0": resolved], resources: resources)
            let request = CancellationToken(), call = CancellationToken()
            let preparer: any NativeConstitutiveSPICEPreparing = SPICENativeSimulation()
            let owner = try await preparer.prepare(input, limits: nativeLimits, osdi: runtime,
                constitutive: snapshot, cancellation: request)
            do {
                let baseline = resources.live + resources.temporary
                let factory = CancelBeforeCaptureReturn(directory: fixture.directory, cancellation: call, hideDirectory: false)
                do {
                    var capture = try await owner.prepareConstitutiveCapture(at: 0,
                        inputs: cancellingInputs(inputs, preparer: factory), cancellation: call)
                    try capture.close(); Issue.record("SPICE delegation published a cancelled capture")
                } catch NativeConstitutiveInspection.Failure.cancelled {}
                #expect(call.isCancelled && !request.isCancelled && resources.live + resources.temporary == baseline)
                var reused = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                _ = try observe(&reused); try reused.close()
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test func combinedCaptureCleanupRetainsActualHelperLeaseUntilRetry() async throws {
        let resources = try Resources()
        try await withSimple(point: true) { fixture, ir, runtime, snapshot, inputs in
            let owner = try await prepare(ir, runtime: runtime, snapshot: snapshot, resources: resources)
            do {
                let before = Set(try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil))
                var capture = try await owner.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                let after = Set(try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil))
                let added = after.subtracting(before)
                try #require(added.count == 1)
                let original = try #require(added.first)
                let held = fixture.directory.appendingPathComponent("held-helper")
                try FileManager.default.moveItem(at: original, to: held)
                let bytes = resources.live + resources.temporary
                var pending: OSDIConstitutiveCaptureCleanup?
                do { try capture.close(); Issue.record("Missing helper staging directory cleanup succeeded") }
                catch OSDIConstitutiveCaptureFailure.cleanupPending(_, _, let cleanup) { pending = cleanup }
                #expect(pending != nil && resources.live + resources.temporary == bytes)
                try FileManager.default.moveItem(at: held, to: original)
                try pending?.close(); try pending?.close(); pending = nil
                #expect(resources.live + resources.temporary < bytes)
                try capture.close()
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
    }

    @Test(arguments: [false, true])
    func allFourOriginalSetupsReachExclusiveNativeCaptureWithSharedPointBacking(pointEnabled: Bool) async throws {
        _ = try Qualification.load()
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: Pin(
            path: Self.environment("OSDI_CONSTITUTIVE_ACTUAL_MANIFEST"),
            sha256: Self.environment("OSDI_CONSTITUTIVE_ACTUAL_MANIFEST_SHA256"), bytes: nil).read())
        let proof = try decoder.decode(CProof.self, from: Pin(
            path: Self.environment("OSDI_CONSTITUTIVE_C_PROOF_RECEIPT"),
            sha256: Self.environment("OSDI_CONSTITUTIVE_C_PROOF_RECEIPT_SHA256"), bytes: nil).read())
        try #require(manifest.schema == "osdi.constitutive-identities-source-binding.v1"
            && manifest.baseSDKRevision == "d10443fb6c1445c986dc35e64030588e77e432a2")
        try #require(proof.schema == "osdi.constitutive-identities-verification.v1" && proof.synthetic == "passed"
            && !proof.rootFlowHistoryAuthority)
        try #require(Set(manifest.cases.map(\.id)) == ["bulk", "cmg", "img", "soi"] && manifest.cases.count == 4)
        var totalWork: UInt64 = 0
        let names = ["bulk": "bsimbulk", "cmg": "bsimcmg_va", "img": "bsimimg", "soi": "bsimsoi"]
        for entry in manifest.cases {
            // Each family has a distinct source/setup request; its point/capture/boxes share this owner.
            let resources = try Resources()
            let original = try decoder.decode(SourceManifest.self, from: entry.sourceInputManifest.read())
            let family = try #require(original.families.first { $0.family == entry.sourceFamily })
            try #require(original.schema == "osdi.internal-chart-singleton-requests.v1" && original.controlBytes == 464)
            try #require(original.inputs.map(\.sha256) == manifest.originalSourceInputPins.map(\.sha256))
            try #require(original.inputs.map(\.path) == manifest.originalSourceInputPins.map(\.path))
            try #require(family.programSHA256 == entry.programSHA256 && family.setupSHA256 == entry.setupSHA256
                && family.requestSHA256 == entry.requestSHA256 && family.pointRequestSHA256 == entry.originalPointRequest.sha256)
            try #require(family.activeUnknownCount == entry.activeUnknownCount && family.rawNodeCount == entry.rawNodeCount
                && family.centerHighBits.count == entry.activeUnknownCount && family.centerLowBits.count == entry.activeUnknownCount)
            let prior = try decoder.decode(CoverReceipt.self, from: entry.priorCoverReceipt.read())
            let qualification = try decoder.decode(CoverQualification.self, from: entry.priorQualification.read())
            try #require(prior.status == "passed" && prior.exitCode == 0 && prior.command.count > 4 && qualification.status == "passed")
            try #require(Array(prior.command[2...4]) == [entry.program, entry.setup, entry.request])
            try #require(qualification.receipts.contains { $0.sha256 == entry.priorCoverReceipt.sha256 })
            let expected = try #require(proof.actualCases.first { $0.id == entry.id })
            try #require(expected.result.status == 0 && expected.result.terminalCount == 1)
            for (path, sha) in [(entry.program, entry.programSHA256), (entry.setup, entry.setupSHA256), (entry.request, entry.requestSHA256)] {
                _ = try Pin(path: path, sha256: sha, bytes: nil).read()
                try #require(expected.inputs.contains { $0.path == path && $0.sha256 == sha })
            }
            // Original control semantics are pinned separately from this caller's quotas.
            let request = try Pin(path: entry.request, sha256: entry.requestSHA256, bytes: nil).read()
            try #require(request.count == 464 + 32 * entry.activeUnknownCount && request.count % 8 == 0)
            func u32(_ offset: Int) -> UInt32 { request.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
            try #require(u32(8) == 2 && u32(12) == 464 && u32(24) == 0x01020304)
            let minimumPrecision = u32(60), maximumPrecision = u32(56)
            try #require(minimumPrecision >= 53 && minimumPrecision <= family.precisionBits
                && family.precisionBits <= maximumPrecision && u32(416) == family.precisionBits)
            let point = try decoder.decode(PointRequest.self, from: entry.originalPointRequest.read())
            let sourceOptions = try point.model.preparation()
            let fixture = try Fixture(library: .init(id: entry.id, path: point.model.libraryPath,
                sha256: point.model.expectedSHA256, descriptorIndex: point.model.descriptorIndex,
                descriptorName: #require(names[entry.id])))
            do {
                #expect(fixture.reference.byteCount == point.model.expectedByteCount)
                let workerPath = fixture.directory.appendingPathComponent("worker")
                try FileManager.default.copyItem(atPath: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER"), toPath: workerPath.path)
                let worker = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                    ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "worker"), role: .input, kind: .model, format: .raw), relativeTo: fixture.directory)
                let expectedWorkerSHA256 = try Self.environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER_SHA256")
                try #require(worker.digest.hexadecimalValue == expectedWorkerSHA256)
                let intent = try ArtifactAccessIntent(expectedReference: worker,
                    availability: .local(artifactID: worker.id, rootID: fixture.provider.root.rootID,
                        relativePath: ArtifactRelativePath(segments: ["worker"])), operation: .read,
                    budget: ArtifactAccessBudget(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                        maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
                let options = try OSDIPrecisionOptions(maximumProgramBytes: 16_777_216, maximumMappingBytes: 268_435_456,
                    arenaBytes: proof.limits.arena_bytes, maximumWorkUnits: proof.limits.work,
                    minimumPrecisionBits: minimumPrecision, maximumPrecisionBits: maximumPrecision, startupTimeoutNanoseconds: 2_000_000_000,
                    evaluationTimeoutNanoseconds: 5_000_000_000, cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
                let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
                let snapshot = NativeConstitutivePreparationInputs(preparer: factory,
                    semanticProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: point.semanticProfileSHA256),
                    options: options, simulationParameters: sourceOptions.simulationParameters)
                let terminals = (0..<point.model.connectedTerminalCount).map { Node(id: $0 + 1) }
                let instance = try fixture.instance("Nactual", nodes: terminals,
                    parameters: point.model.parameters.filter { $0.scope == "instance" }.map { try $0.assignment() },
                    modelParameters: point.model.parameters.filter { $0.scope == "model" }.map { try $0.assignment() })
                let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
                    loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 67_108_864),
                    evaluationLimits: sourceOptions.limits, maximumInstanceCount: 1, maximumAdapterBytes: 1_073_741_824,
                    tolerances: SPICEOSDITolerances(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12),
                    transientPrecision: pointEnabled ? OSDITransientPrecisionInputs(preparer: factory, worker: intent,
                        source: fixture.provider.root, semanticProfile: snapshot.semanticProfile,
                        numericProfile: try ContentDigest(algorithm: .sha256,
                            hexadecimalValue: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")),
                        options: options, precisionBits: family.precisionBits) : nil)
                let preparer: any NativeConstitutiveCircuitPreparing = NativeCircuitPreparer()
                let prepared = try await preparer.prepare(ir: CircuitIR(nodes: terminals, branches: [], instances: [instance]),
                    registry: .standard(), operatingConditions: OperatingConditions(temperatureKelvin: point.model.temperatureKelvin),
                    limits: nativeLimits, numericalLimits: numericalLimits, resources: resources,
                    osdi: runtime, constitutive: snapshot, cancellation: .init())
                do {
                    let backing = try #require(prepared.record.constitutiveBacking)
                    let saved = try #require(backing.programs.first)
                    #expect(prepared.record.compileCapacity == resources.live + resources.temporary)
                    #expect(saved.programDigest.hexadecimalValue == entry.programSHA256)
                    #expect(saved.setupDigest.hexadecimalValue == entry.setupSHA256)
                    #expect(prepared.record.osdiPreparationRecords.count == 1)
                    let pointReceipt = prepared.record.osdiPreparationRecords[0].transientPrecision
                    #expect((pointReceipt != nil) == pointEnabled)
                    if let pointReceipt {
                        #expect(pointReceipt.program.programDigest == saved.programDigest
                            && pointReceipt.program.setupDigest == saved.setupDigest)
                        #expect(pointReceipt.program.programByteCount == saved.programByteCount
                            && pointReceipt.program.setupByteCount == saved.setupByteCount)
                        #expect(pointReceipt.options == options && pointReceipt.precisionBits == family.precisionBits)
                        #expect(pointReceipt.workerReference == worker)
                    }
                    #expect(saved.topology.activeUnknownCount == entry.activeUnknownCount && saved.topology.nodes.count == entry.rawNodeCount)
                    let inputs = OSDIConstitutiveCaptureInputs(preparer: factory, evaluator: OSDINativePrecisionEvaluator(),
                        worker: intent, source: fixture.provider.root,
                        numericProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: Self.environment("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")),
                        options: options,
                        coverLimits: try OSDIPrecisionDecisionCoverLimits(maximumSteps: proof.limits.steps,
                            maximumGuardRecords: proof.limits.steps, maximumCopiedBytes: 268_435_456,
                            maximumCells: 100, maximumNodes: 20_000, maximumLeaves: 64, maximumPending: 20_000,
                            maximumDepth: 20_000, maximumIntegerBits: 1025),
                        limits: try OSDIPrecisionConstitutiveLimits(maximumNodes: proof.limits.maximum_nodes,
                            maximumAtoms: proof.limits.maximum_atoms, maximumCoefficientBits: proof.limits.coefficient_bits,
                            maximumWorkspaceBytes: proof.limits.workspace_bytes))
                    var capture = try await prepared.prepareConstitutiveCapture(at: 0, inputs: inputs, cancellation: .init())
                    do {
                        let high = family.centerHighBits.map(Double.init(bitPattern:)), low = family.centerLowBits.map(Double.init(bitPattern:))
                        let time = try OSDIPrecisionContext(mode: .transient, timeHigh: Double(bitPattern: family.context.timeHighBits),
                            timeLow: Double(bitPattern: family.context.timeLowBits))
                        var work: UInt64 = 0
                        for sequence in 1...2 {
                            try capture.withCheckedIdentities(lowerHigh: high.span, lowerLow: low.span,
                                upperHigh: high.span, upperLow: low.span, lowerContext: time, upperContext: time,
                                precisionBits: family.precisionBits) { view, inventory in
                                    compare(view, inventory: inventory, expected: expected.result, source: family,
                                        binding: OSDIPrecisionChartBinding(program: saved))
                                    let actualTime = view.cover.lowerContext, upperTime = view.cover.upperContext
                                    let actualSequence = view.cover.requestSequence, completed = view.cover.completedWorkUnits
                                    #expect(actualTime == time && upperTime == time && actualSequence == UInt64(sequence) && completed > work)
                                    work = completed
                                }
                        }
                    } catch { try capture.close(); throw error }
                    try capture.close(); try capture.close()
                } catch { try prepared.close(); throw error }
                try prepared.close()
            } catch { try await fixture.close(); throw error }
            try await fixture.close()
            #expect(resources.live == 0 && resources.temporary == 0 && resources.reservations == resources.releases)
            #expect(resources.work >= UInt64(pointEnabled ? 2 : 1) * proof.limits.work)
            totalWork += resources.work
        }
        #expect(totalWork >= UInt64(pointEnabled ? 8 : 4) * proof.limits.work)
    }
}
