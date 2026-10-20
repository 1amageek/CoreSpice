import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDI
import OSDIRuntime
import CoreSpiceOSDIContracts
import Foundation
import OSDIContracts

/// Bounded host JSON input; semantic values are portable and paths grant only exact local availability.
struct CoreSpiceCLIOSDICatalog: Decodable, Sendable {
    let transientPrecision: PrecisionInput?
    let executionBudget: CoreSpiceCLIPrecisionExecutionBudget?
    let schemaVersion: Int
    let baseCatalogSchemaVersion: Int?
    let simulationParameters: [CoreSpiceCLIOSDISimulationParameterRecord]?
    let libraryRootPath: String
    let stagingParentDirectory: String
    let artifacts: [Artifact]
    let instances: [InstanceInput]
    let loadLimits: LoadLimits
    let evaluationLimits: EvaluationLimits
    let maximumInstanceCount: Int
    let maximumAdapterBytes: UInt64
    let tolerances: Tolerances

    private enum CodingKeys: String, CodingKey {
        case transientPrecision, executionBudget, schemaVersion, baseCatalogSchemaVersion, simulationParameters
        case libraryRootPath, stagingParentDirectory, artifacts, instances, loadLimits, evaluationLimits
        case maximumInstanceCount, maximumAdapterBytes, tolerances
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        if schemaVersion == 3 {
            let base = try c.decode(Int.self, forKey: .baseCatalogSchemaVersion)
            let parameters = try c.decode([CoreSpiceCLIOSDISimulationParameterRecord].self, forKey: .simulationParameters)
            guard [1, 2].contains(base), !parameters.isEmpty,
                  Set(parameters.map(\.name)).count == parameters.count else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Invalid explicit simulation catalog base or parameters")
            }
            baseCatalogSchemaVersion = base; simulationParameters = parameters
        } else {
            guard !c.contains(.baseCatalogSchemaVersion), !c.contains(.simulationParameters) else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Simulation parameters require catalog schema 3")
            }
            baseCatalogSchemaVersion = nil; simulationParameters = nil
        }
        transientPrecision = try c.decodeIfPresent(PrecisionInput.self, forKey: .transientPrecision)
        executionBudget = try c.decodeIfPresent(CoreSpiceCLIPrecisionExecutionBudget.self, forKey: .executionBudget)
        libraryRootPath = try c.decode(String.self, forKey: .libraryRootPath)
        stagingParentDirectory = try c.decode(String.self, forKey: .stagingParentDirectory)
        artifacts = try c.decode([Artifact].self, forKey: .artifacts)
        instances = try c.decode([InstanceInput].self, forKey: .instances)
        loadLimits = try c.decode(LoadLimits.self, forKey: .loadLimits)
        evaluationLimits = try c.decode(EvaluationLimits.self, forKey: .evaluationLimits)
        maximumInstanceCount = try c.decode(Int.self, forKey: .maximumInstanceCount)
        maximumAdapterBytes = try c.decode(UInt64.self, forKey: .maximumAdapterBytes)
        tolerances = try c.decode(Tolerances.self, forKey: .tolerances)
    }

    struct PrecisionInput: Decodable, Sendable {
        let workerRootPath: String
        let worker: Artifact
        let semanticProfileSHA256: String
        let numericProfileSHA256: String
        let options: CoreSpiceCLIPrecisionOptions
        let precisionBits: UInt32
        func checked(stagingParentDirectory: String) throws -> OSDITransientPrecisionInputs {
            guard workerRootPath.hasPrefix("/"), !workerRootPath.contains("\0") else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Precision worker root must be absolute")
            }
            let root = try ArtifactRootID(rawValue: UUID().uuidString)
            let intent = try ArtifactAccessIntent(expectedReference: worker.reference,
                availability: .local(artifactID: worker.reference.id, rootID: root,
                    relativePath: .init(segments: worker.relativePath)), operation: .read, budget: worker.accessBudget.checked())
            let value = try options.checked()
            guard precisionBits >= value.minimumPrecisionBits && precisionBits <= value.maximumPrecisionBits else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Precision bits are outside explicit policy")
            }
            return OSDITransientPrecisionInputs(preparer: OSDINativePrecisionSessionPreparer(stagingParentDirectory: URL(fileURLWithPath: stagingParentDirectory, isDirectory: true)), worker: intent,
                source: try SPICEOSDILocalArtifactSource(rootID: root, directoryURL: URL(fileURLWithPath: workerRootPath, isDirectory: true), digester: SHA256ContentDigester()),
                semanticProfile: try .init(algorithm: .sha256, hexadecimalValue: semanticProfileSHA256),
                numericProfile: try .init(algorithm: .sha256, hexadecimalValue: numericProfileSHA256),
                options: value, precisionBits: precisionBits)
        }
    }
    struct Artifact: Decodable, Sendable {
        let reference: ArtifactReference
        let relativePath: [String]
        let accessBudget: AccessBudget
    }
    struct AccessBudget: Decodable, Sendable {
        let maximumPageByteCount: UInt64
        let maximumTotalByteCount: UInt64
        let maximumPageCount: UInt64
        let maximumWorkUnitCount: UInt64
        let maximumDurationNanoseconds: UInt64
        func checked() throws -> ArtifactAccessBudget {
            try .init(maximumPageByteCount: maximumPageByteCount, maximumTotalByteCount: maximumTotalByteCount,
                maximumPageCount: maximumPageCount, maximumWorkUnitCount: maximumWorkUnitCount,
                maximumDurationNanoseconds: maximumDurationNanoseconds)
        }
    }
    struct InstanceInput: Decodable, Sendable {
        let instanceName: String
        let modelName: String
        let artifact: ArtifactReference
        let descriptorIndex: Int
        let expectedDescriptorName: String
        let modelParameters: [CoreSpiceCLIOSDIParameterRecord]
        let instanceParameters: [CoreSpiceCLIOSDIParameterRecord]
        let previousState: [Double]
        func checked() throws -> OSDIResolvedInstance {
            guard (modelParameters + instanceParameters).allSatisfy({ $0.descriptorIndex == nil && $0.isGiven == nil }) else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Input assignments cannot claim resolved descriptor facts")
            }
            return try .init(binding: .init(modelName: modelName, artifact: artifact, descriptorIndex: descriptorIndex,
                expectedDescriptorName: expectedDescriptorName, modelParameters: modelParameters.map { try $0.assignment() }),
                instanceParameters: instanceParameters.map { try $0.assignment() }, previousState: previousState)
        }
    }
    struct LoadLimits: Decodable, Sendable {
        let maximumDescriptors: UInt32
        let maximumMetadataBytes: UInt64
        let maximumStorageBytes: UInt64
        func checked() throws -> OSDILoadLimits {
            try .init(maximumDescriptors: maximumDescriptors, maximumMetadataBytes: maximumMetadataBytes, maximumStorageBytes: maximumStorageBytes)
        }
    }
    struct EvaluationLimits: Decodable, Sendable {
        let maximumWorkspaceBytes: UInt64
        let maximumDiagnosticCount: UInt32
        let maximumDiagnosticBytes: UInt64
        let maximumStringBytes: UInt64
        func checked() throws -> OSDIEvaluationLimits {
            try .init(maximumWorkspaceBytes: maximumWorkspaceBytes, maximumDiagnosticCount: maximumDiagnosticCount,
                maximumDiagnosticBytes: maximumDiagnosticBytes, maximumStringBytes: maximumStringBytes)
        }
    }
    struct Tolerances: Decodable, Sendable {
        let temperatureAbsoluteKelvin: Double
        let thermalResidualAbsoluteWatts: Double
    }
    struct Loaded: Sendable {
        let sourcePath: String
        let sourceBytes: Data
        let evidenceInputPaths: [String: ArtifactReference]
        let protectedInputPaths: [String]
        let executionBudget: CoreSpiceCLIPrecisionExecutionBudget?
        let sourceReference: ArtifactReference
        let instances: [String: OSDIResolvedInstance]
        let runtime: SPICEOSDIRuntimeInputs
    }
    static func load(path: String) throws -> Loaded {
        do { return try loadChecked(path: path) }
        catch let error as CoreSpiceCLIOSDIError { throw error }
        catch { throw CoreSpiceCLIOSDIError.invalidCatalog(String(describing: error)) }
    }
    private static func loadChecked(path: String) throws -> Loaded {
        // CLI developer catalog policy v1 bounds UTF-8 decoding and all JSON collection materialization.
        let bytes = try LocalSPICESourceReader().read(at: path, maximumByteCount: 4 * 1024 * 1024, maximumPageByteCount: 4096)
        let catalog = try JSONDecoder().decode(Self.self, from: bytes)
        guard [1, 2, 3].contains(catalog.schemaVersion), catalog.libraryRootPath.hasPrefix("/"),
              catalog.stagingParentDirectory.hasPrefix("/"), !catalog.instances.isEmpty,
              catalog.instances.count <= catalog.maximumInstanceCount, !catalog.artifacts.isEmpty,
              catalog.artifacts.count <= catalog.instances.count else {
            throw CoreSpiceCLIOSDIError.invalidCatalog("Invalid catalog schema, root paths, counts or explicit bounds")
        }
        let baseSchema = catalog.baseCatalogSchemaVersion ?? catalog.schemaVersion
        if baseSchema == 1 {
            guard catalog.transientPrecision == nil && catalog.executionBudget == nil else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Schema1 cannot request precision or a replacement execution budget")
            }
        } else {
            guard catalog.transientPrecision != nil, let budget = catalog.executionBudget else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Schema2 requires precision and all explicit execution budgets")
            }
            try budget.validate()
        }
        let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
        var intents: [ArtifactAccessIntent] = []
        for artifact in catalog.artifacts {
            guard !intents.contains(where: { $0.expectedReference == artifact.reference }) else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Duplicate artifact reference")
            }
            intents.append(try .init(expectedReference: artifact.reference,
                availability: .local(artifactID: artifact.reference.id, rootID: rootID,
                    relativePath: .init(segments: artifact.relativePath)), operation: .read, budget: artifact.accessBudget.checked()))
        }
        var selected: [String: OSDIResolvedInstance] = [:]
        for instance in catalog.instances {
            guard !instance.instanceName.isEmpty, selected[instance.instanceName] == nil,
                  intents.contains(where: { $0.expectedReference == instance.artifact }) else {
                throw CoreSpiceCLIOSDIError.invalidCatalog("Duplicate instance name or unavailable exact artifact")
            }
            selected[instance.instanceName] = try instance.checked()
        }
        guard intents.allSatisfy({ intent in selected.values.contains { $0.binding.artifact == intent.expectedReference } }) else {
            throw CoreSpiceCLIOSDIError.invalidCatalog("Unused artifact catalog entry")
        }
        let provider = try SPICEOSDILocalLibraryProvider(rootID: rootID,
            directoryURL: URL(fileURLWithPath: catalog.libraryRootPath, isDirectory: true), intents: intents,
            stagingParentDirectory: URL(fileURLWithPath: catalog.stagingParentDirectory, isDirectory: true), digester: SHA256ContentDigester())
        let runtime = try SPICEOSDIRuntimeInputs(provider: provider, loadLimits: catalog.loadLimits.checked(),
            evaluationLimits: catalog.evaluationLimits.checked(), maximumInstanceCount: catalog.maximumInstanceCount,
            maximumAdapterBytes: catalog.maximumAdapterBytes, tolerances: .init(
                temperatureAbsoluteKelvin: catalog.tolerances.temperatureAbsoluteKelvin,
                thermalResidualAbsoluteWatts: catalog.tolerances.thermalResidualAbsoluteWatts),
            transientPrecision: try catalog.transientPrecision?.checked(stagingParentDirectory: catalog.stagingParentDirectory),
            simulationParameters: try catalog.simulationParameters?.map { try $0.simulationParameter() })
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(max(1, bytes.count)), maximumTotalByteCount: UInt64(max(1, bytes.count)), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(Array(bytes))
        }
        let reference = try ArtifactReference(digest: digest.digest, byteCount: UInt64(bytes.count),
            descriptor: .init(role: .input, kind: .model, format: .json))
        var protectedPaths = [path]
        for artifact in catalog.artifacts {
            protectedPaths.append(artifact.relativePath.reduce(URL(fileURLWithPath: catalog.libraryRootPath)) { $0.appendingPathComponent($1) }.path)
        }
        if let precision = catalog.transientPrecision {
            protectedPaths.append(precision.worker.relativePath.reduce(URL(fileURLWithPath: precision.workerRootPath)) { $0.appendingPathComponent($1) }.path)
        }
        var evidenceInputPaths = [path: reference]
        for artifact in catalog.artifacts {
            let artifactPath = artifact.relativePath.reduce(URL(fileURLWithPath: catalog.libraryRootPath)) { $0.appendingPathComponent($1) }.path
            evidenceInputPaths[artifactPath] = artifact.reference
        }
        if let precision = catalog.transientPrecision {
            let workerPath = precision.worker.relativePath.reduce(URL(fileURLWithPath: precision.workerRootPath)) { $0.appendingPathComponent($1) }.path
            evidenceInputPaths[workerPath] = precision.worker.reference
        }
        return Loaded(sourcePath: path, sourceBytes: bytes, evidenceInputPaths: evidenceInputPaths, protectedInputPaths: protectedPaths, executionBudget: catalog.executionBudget, sourceReference: reference, instances: selected, runtime: runtime)
    }
}
