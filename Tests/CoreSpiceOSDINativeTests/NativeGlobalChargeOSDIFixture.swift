import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR
import Foundation
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpice

/// Test-only acquisition of the already qualified original source images and public worker.
struct NativeGlobalChargeOSDIFixture {
    let directory: URL
    let root: ArtifactRootCapability
    let provider: SPICEOSDILocalLibraryProvider
    let linear: ArtifactReference
    let parabola: ArtifactReference
    let worker: ArtifactAccessIntent
    let snapshot: NativeConstitutivePreparationInputs
    let capture: OSDIConstitutiveCaptureInputs
    let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
        maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 16,
        maximumWorkUnits: 1_000_000, maximumBreakpoints: 10)
    let nativeLimits = SPICENativeExecutionLimits(maximumDeviceCount: 16,
        maximumMatrixDimension: 16, maximumAllocationBytes: 268_435_456)

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) throws -> String { try #require(environment[key], "Missing qualified fixture input: \(key)") }
        let semantic = try value("CORESPICE_GLOBAL_CHARGE_SEMANTIC_SHA256")
        let numeric = try value("OSDI_PRECISION_NUMERIC_PROFILE_SHA256")
        try #require(semantic == "a85f38191b22ccf3b084f0892ee0fa51752d37f0defa6b62dee929935be35104")
        try #require(numeric == "9aa1a0cf67ead02c06ef5fdbd10ffa78ec79a2937c5b9a6d12612569fd879e59")
        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("global-charge-\(UUID().uuidString)")
        directory = stagingDirectory
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
        func stage(_ path: String, name: String, digest: String) throws -> ArtifactAccessIntent {
            try FileManager.default.copyItem(atPath: path, toPath: stagingDirectory.appendingPathComponent(name).path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: name), role: .input, kind: .model, format: .raw),
                relativeTo: stagingDirectory)
            try #require(reference.digest.hexadecimalValue == digest)
            return try .init(expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: rootID, relativePath: ArtifactRelativePath(segments: [name])),
                operation: .read, budget: .init(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
        }
        let a = try stage(value("CORESPICE_GLOBAL_CHARGE_LINEAR_LIBRARY"), name: "linear.osdi",
            digest: "25f3f51c385252ce34876ca990aa6e932bf7a4c1948237b0100d03749158d846")
        let b = try stage(value("CORESPICE_GLOBAL_CHARGE_PARABOLA_LIBRARY"), name: "parabola.osdi",
            digest: "364a8156c02330c7fe710cadcc468617f6fa4c7f0183db1da6cf30806f08a927")
        worker = try stage(value("OSDI_PRECISION_WORKER"), name: "worker",
            digest: "94e44eb3aa87677877ae792fbf285f8f1ea70da3dac57446d0ec11d39df05187")
        linear = a.expectedReference; parabola = b.expectedReference
        provider = try .init(rootID: rootID, directoryURL: directory, intents: [a, b],
            stagingParentDirectory: directory, digester: SHA256ContentDigester())
        root = try .init(rootID: rootID, directoryURL: directory, digester: SHA256ContentDigester())
        let options = try OSDIPrecisionOptions(maximumProgramBytes: 1_048_576, maximumMappingBytes: 16_777_216,
            arenaBytes: 16_777_216, maximumWorkUnits: 100_000_000, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
            startupTimeoutNanoseconds: 2_000_000_000, evaluationTimeoutNanoseconds: 2_000_000_000,
            cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
        let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: directory)
        snapshot = .init(preparer: factory, semanticProfile: try .init(algorithm: .sha256, hexadecimalValue: semantic), options: options)
        capture = .init(preparer: factory, evaluator: OSDINativePrecisionEvaluator(), worker: worker, source: root,
            numericProfile: try .init(algorithm: .sha256, hexadecimalValue: numeric), options: options,
            coverLimits: try .init(maximumSteps: 100_000, maximumGuardRecords: 100_000, maximumCopiedBytes: 10_000_000,
                maximumCells: 100, maximumNodes: 256, maximumLeaves: 64, maximumPending: 256, maximumDepth: 256, maximumIntegerBits: 1025),
            limits: try .init(maximumNodes: 256, maximumAtoms: 64, maximumCoefficientBits: 4096, maximumWorkspaceBytes: 2_097_152))
    }
    func instance(_ name: String, nodes: [Node], capacitance: Double? = 1) throws -> Instance {
        let parameters: [OSDIParameterAssignment]
        if let capacitance {
            parameters = [try .init(name: "conductance", scope: .model, value: .real(0)),
                try .init(name: "capacitance", scope: .model, value: .real(capacitance))]
        } else { parameters = [] }
        let binding = try OSDIModelBinding(modelName: name, artifact: capacitance == nil ? parabola : linear,
            descriptorIndex: 0, expectedDescriptorName: capacitance == nil ? "global_charge_parabola" : "linear_rc", modelParameters: parameters)
        return try .init(name: name, typeName: "osdi", nodes: nodes, parameters: [:],
            osdi: .resolved(OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])))
    }
    func prepare(_ instances: [Instance], nodes: [Node], resources: any SPICESourceResourceAccounting) async throws -> PreparedNativeCircuit {
        let runtime = try SPICEOSDIRuntimeInputs(provider: provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: instances.count,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let owner = try await NativeCircuitPreparer().prepare(ir: CircuitIR(nodes: nodes, branches: [], instances: instances),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15), limits: nativeLimits,
            numericalLimits: numerical, resources: resources, osdi: runtime, constitutive: snapshot, cancellation: .init())
        do {
            let programs = try #require(owner.record.constitutiveBacking?.programs)
            try #require(programs.count == instances.filter { $0.osdi != nil }.count)
            var index = 0
            for instance in instances where instance.osdi != nil {
                let program = programs[index]
                index += 1
                try #require(program.modelReference == instance.osdi?.resolved.binding.artifact)
                let isLinear = program.modelReference == linear
                try #require(program.programDigest.hexadecimalValue == (isLinear
                    ? "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203"
                    : "22bf1ebc619fcf7473d5845ad970638ef9a3a3123a8592b50538f522ebebc205"))
                try #require(program.topology.nodes.count == 2 && program.topology.activeUnknownCount == 2)
            }
        } catch { try owner.close(); throw error }
        return consume owner
    }
    func replacingEvaluator(_ evaluator: any OSDIPrecisionConstitutiveEvaluating) -> OSDIConstitutiveCaptureInputs {
        .init(preparer: capture.preparer, evaluator: evaluator, worker: capture.worker, source: capture.source,
            numericProfile: capture.numericProfile, options: capture.options, coverLimits: capture.coverLimits, limits: capture.limits)
    }
    func close() async throws {
        try await root.close().wait()
        // A successful owner/capture close removes every temporary staging tree.
        try #require(Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(["linear.osdi", "parabola.osdi", "worker"]))
        try FileManager.default.removeItem(at: directory)
    }
}
