import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
import CoreSpiceIO
@testable import CoreSpiceOSDI
import CoreSpiceOSDITestSupport
import OSDIContracts
import OSDIRuntime
import Synchronization
import Testing

struct OSDIPrecisionNativeFixture {
    let manifest: OSDIPrecisionManifest
    let analysis: OSDIAnalysisNativeFixture
    let worker: ArtifactAccessIntent
    let source: SPICEOSDILocalArtifactSource
    let preparer: CountingNativePrecisionPreparer
    let options: OSDIPrecisionOptions
    let adapterBytes: UInt64
    let managedWorkerBytes: UInt64

    init() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_MANIFEST"])
        manifest = try JSONDecoder().decode(OSDIPrecisionManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(manifest.schema == "corespice.osdi.precision-manifest.v1")
        options = try manifest.options.value()
        analysis = try OSDIAnalysisNativeFixture(libraries: manifest.models.map(\.library))
        do {
            var extra: UInt64 = 0
            for model in manifest.models {
                let reference = try #require(analysis.base.references[model.id])
                #expect(reference.byteCount == model.byteCount)
                let library = try await analysis.base.provider.load(reference: reference,
                    limits: .init(maximumDescriptors: 16, maximumMetadataBytes: 4 * 1024 * 1024, maximumStorageBytes: 4 * 1024 * 1024))
                do {
                    let descriptor = try #require(library.descriptors.first { Int($0.index) == model.descriptorIndex })
                    extra = max(extra, try OSDIAdapterCapacity.precision(nodeCount: descriptor.nodeCount, options: options))
                } catch { try library.close(); throw error }
                try library.close()
            }
            adapterBytes = 8 * 1024 * 1024 + extra
            managedWorkerBytes = options.maximumMappingBytes + options.arenaBytes
            let file = analysis.base.directory.appendingPathComponent("precision-worker")
            try FileManager.default.copyItem(atPath: manifest.worker.path, toPath: file.path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                .init(location: ArtifactLocation(workspaceRelativePath: "precision-worker"), role: .input, kind: .other, format: .raw),
                relativeTo: analysis.base.directory)
            #expect(reference.digest.hexadecimalValue == manifest.worker.sha256 && reference.byteCount == manifest.worker.byteCount)
            let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
            source = try .init(rootID: rootID, directoryURL: analysis.base.directory, digester: SHA256ContentDigester())
            worker = try .init(expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: rootID,
                    relativePath: ArtifactRelativePath(segments: ["precision-worker"])), operation: .read,
                budget: ArtifactAccessBudget(maximumPageByteCount: min(65536, reference.byteCount),
                    maximumTotalByteCount: reference.byteCount, maximumPageCount: 65536,
                    maximumWorkUnitCount: 65536, maximumDurationNanoseconds: 10_000_000_000))
            preparer = CountingNativePrecisionPreparer(directory: analysis.base.directory)
        } catch {
            do { try analysis.base.close() }
            catch let cleanup { throw ArtifactAccessError.cleanupFailed(primary: String(describing: error), closeReason: String(describing: cleanup)) }
            throw error
        }
    }

    func close() throws { try analysis.base.close() }

    var limits: SPICENativeExecutionLimits {
        .init(maximumDeviceCount: 256, maximumMatrixDimension: 256,
            maximumAllocationBytes: 64 * 1024 * 1024 + managedWorkerBytes + adapterBytes - 8 * 1024 * 1024)
    }

    func resources() throws -> SPICESimulationResources {
        try .init(maximumLiveBytes: 128 * 1024 * 1024 + managedWorkerBytes + adapterBytes - 8 * 1024 * 1024,
            maximumTemporaryBytes: 128 * 1024 * 1024, maximumWorkUnits: 1_000_000_000,
            maximumHashedBytes: 64 * 1024 * 1024)
    }

    func precision(options: OSDIPrecisionOptions? = nil, bits: UInt32? = nil,
                   semantic: ContentDigest? = nil, numeric: ContentDigest? = nil,
                   worker: ArtifactAccessIntent? = nil) throws -> OSDITransientPrecisionInputs {
        .init(preparer: preparer, worker: worker ?? self.worker, source: source,
            semanticProfile: try semantic ?? ContentDigest(algorithm: .sha256, hexadecimalValue: manifest.semanticProfileSHA256),
            numericProfile: try numeric ?? ContentDigest(algorithm: .sha256, hexadecimalValue: manifest.numericProfileSHA256),
            options: options ?? self.options, precisionBits: bits ?? manifest.precisionBits)
    }

    func changingOptions(programBytes: UInt64? = nil, workUnits: UInt64? = nil) throws -> OSDIPrecisionOptions {
        try .init(maximumProgramBytes: programBytes ?? options.maximumProgramBytes,
            maximumMappingBytes: options.maximumMappingBytes, arenaBytes: options.arenaBytes,
            maximumWorkUnits: workUnits ?? options.maximumWorkUnits,
            minimumPrecisionBits: options.minimumPrecisionBits, maximumPrecisionBits: options.maximumPrecisionBits,
            startupTimeoutNanoseconds: options.startupTimeoutNanoseconds,
            evaluationTimeoutNanoseconds: options.evaluationTimeoutNanoseconds,
            cleanupTimeoutNanoseconds: options.cleanupTimeoutNanoseconds, pollNanoseconds: options.pollNanoseconds)
    }

    func runtime(_ point: OSDIAnalysisManifest.Case? = nil, provider: (any OSDILibraryProviding)? = nil,
                 precision: OSDITransientPrecisionInputs? = nil) throws -> SPICEOSDIRuntimeInputs {
        let policy = point?.input.circuit.policy
        return try .init(provider: provider ?? analysis.base.provider,
            loadLimits: .init(maximumDescriptors: 16, maximumMetadataBytes: 4 * 1024 * 1024, maximumStorageBytes: 4 * 1024 * 1024),
            evaluationLimits: .init(maximumWorkspaceBytes: 8 * 1024 * 1024, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65536, maximumStringBytes: 65536), maximumInstanceCount: 16,
            maximumAdapterBytes: adapterBytes,
            tolerances: .init(temperatureAbsoluteKelvin: policy?.unknownAbsoluteTolerances["K"] ?? 1e-6,
                thermalResidualAbsoluteWatts: policy?.equationAbsoluteTolerances["W"] ?? 1e-12),
            transientPrecision: try precision ?? self.precision())
    }

    func input(modelID: String = "compound", parameter: OSDIParameterAssignment? = nil,
               unsupportedMixedDevice: Bool = false) async throws -> PreparedSPICESimulation {
        let model = try #require(manifest.models.first { $0.id == modelID })
        let reference = try #require(analysis.base.references[model.id])
        let binding = try OSDIModelBinding(modelName: "model", artifact: reference,
            descriptorIndex: model.descriptorIndex, expectedDescriptorName: model.descriptorName,
            modelParameters: parameter.map { [$0] } ?? [])
        let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])
        let h = modelID == "context" ? 1e-9 : 0x1p-54
        let current = modelID == "context" ? 1.0 : 2.0 + 0x1p-30
        var lines = ["Native precision \(modelID)", ".model model osdi", "N1 p model", "I1 p 0 \(-current)"]
        if unsupportedMixedDevice { lines.append("E1 x 0 p 0 1") }
        lines += [".ic V(p)=1", ".options gmin=0 reltol=1e-10 abstol=1e-12 vntol=1e-9 itl1=80",
                  ".tran \(h) \(4 * h) 0 \(h) uic", ".end"]
        return try await analysis.base.source(lines.joined(separator: "\n") + "\n", catalog: ["n1": resolved], resources: resources())
    }

    func pilotInput(_ point: OSDIAnalysisManifest.Case) async throws -> PreparedSPICESimulation {
        let first = try #require(point.input.analysis.steps?.first)
        return try await analysis.input(point, stopTimeOverride: first.timeSeconds, resources: resources())
    }

    func digest(_ bytes: [UInt8]) throws -> ContentDigest {
        try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }.digest
    }
}

final class CountingNativePrecisionPreparer: OSDIPrecisionSessionPreparing {
    private let factory: OSDINativePrecisionSessionPreparer
    private let counts = Mutex((snapshots: 0, launches: 0))
    var snapshotCount: Int { counts.withLock { $0.snapshots } }
    var launchCount: Int { counts.withLock { $0.launches } }
    init(directory: URL) { factory = .init(stagingParentDirectory: directory) }

    func snapshot(library: borrowing OSDILibrary, descriptorIndex: Int, model: borrowing OSDIPreparedModel,
                  preparation: OSDIPreparationOptions, semanticProfile: ContentDigest,
                  options: OSDIPrecisionOptions) throws(OSDIError) -> OSDIPrecisionProgram {
        counts.withLock { $0.snapshots += 1 }
        return try factory.snapshot(library: library, descriptorIndex: descriptorIndex, model: model,
            preparation: preparation, semanticProfile: semanticProfile, options: options)
    }
    func prepare(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent, source: any ArtifactAccessing,
                 numericProfile: ContentDigest, options: OSDIPrecisionOptions) async throws(OSDIError) -> OSDIPrecisionSession {
        counts.withLock { $0.launches += 1 }
        return try await factory.prepare(program: program, worker: worker, source: source, numericProfile: numericProfile, options: options)
    }
}
