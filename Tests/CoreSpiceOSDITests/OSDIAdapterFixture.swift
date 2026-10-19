import CoreSpiceOSDITestSupport
import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDIContracts
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpiceOSDI

struct OSDIAdapterFixture {
    struct Manifest: Decodable { let libraries: [Library] }
    typealias Library = OSDIDCManifest.Library
    let library: Library
    let directory: URL
    let reference: ArtifactReference
    let provider: Provider

    init(descriptor: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_MANIFEST"] else {
            throw FixtureFailure.missingManifest
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let library = manifest.libraries.first(where: { $0.descriptorName == descriptor }) else { throw FixtureFailure.missingDescriptor }
        try self.init(library: library)
    }
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
    func prepare(_ instances: [Instance], maximumInstanceCount: Int = 16,
                 maximumAdapterBytes: UInt64 = 16_777_216) async throws -> OSDIPreparedCircuit {
        let nodes = Array(Set(instances.flatMap(\.nodes))).sorted { $0.id < $1.id }
        return try await prepareCircuit(CircuitIR(nodes: nodes, branches: [], instances: instances),
            maximumInstanceCount: maximumInstanceCount, maximumAdapterBytes: maximumAdapterBytes)
    }
    func prepareCircuit(_ ir: CircuitIR, maximumInstanceCount: Int = 16,
                        maximumAdapterBytes: UInt64 = 16_777_216) async throws -> OSDIPreparedCircuit {
        return try await OSDICircuitPreparer().prepare(ir: ir,
            operatingConditions: .nominal, provider: provider,
            loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 16_777_216),
            evaluationLimits: OSDIEvaluationLimits(maximumWorkspaceBytes: 16_777_216, maximumDiagnosticCount: 64,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: maximumInstanceCount, maximumAdapterBytes: maximumAdapterBytes)
    }
    func context(_ topology: CircuitTopology) -> BindingContext {
        let dimension = topology.matrixSize
        return BindingContext(variableMap: topology.variableMap, matrixDimension: dimension,
            stampIndexResolver: { row, col in row * dimension + col })
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
