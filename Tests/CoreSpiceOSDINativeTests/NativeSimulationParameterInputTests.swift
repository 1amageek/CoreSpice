import Testing
import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import OSDIContracts
import OSDIRuntime
@testable import CoreSpice

@Suite(.timeLimit(.minutes(1)))
struct NativeSimulationParameterInputTests {
    private struct Provider: OSDILibraryProviding {
        func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
            throw .identityMismatch
        }
    }
    private func runtime(_ parameters: [OSDISimulationParameter]? = nil) throws -> SPICEOSDIRuntimeInputs {
        try SPICEOSDIRuntimeInputs(provider: Provider(),
            loadLimits: OSDILoadLimits(maximumDescriptors: 1, maximumMetadataBytes: 4096, maximumStorageBytes: 4096),
            evaluationLimits: OSDIEvaluationLimits(maximumWorkspaceBytes: 4096, maximumDiagnosticCount: 1,
                maximumDiagnosticBytes: 4096, maximumStringBytes: 4096), maximumInstanceCount: 1,
            maximumAdapterBytes: 1_048_576,
            tolerances: SPICEOSDITolerances(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12),
            simulationParameters: parameters)
    }
    private func receipt(_ parameters: [OSDISimulationParameter]) throws -> OSDIPreparationReceipt {
        let artifact = try ArtifactReference(digest: ContentDigest(algorithm: .sha256,
            hexadecimalValue: String(repeating: "a", count: 64)), byteCount: 1,
            descriptor: ArtifactDescriptor(role: .input, kind: .model, format: .raw))
        let binding = try OSDIModelBinding(modelName: "model", artifact: artifact, descriptorIndex: 0,
            expectedDescriptorName: "model", modelParameters: [])
        return try OSDIPreparationReceipt(resolved: OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: []),
            effectiveTemperatureKelvin: 298.15, topology: OSDIPreparedTopology(nodes: [], activeUnknownCount: 0, stateCount: 0),
            resolvedParameters: [], simulationParameters: parameters)
    }
    private func identity(_ parameters: [OSDISimulationParameter], input: SPICEOSDIRuntimeInputs? = nil) throws -> ContentDigest {
        let actual = try input ?? runtime(parameters)
        let record = NativeOSDIPreparationRecord(instanceName: "N1", receipt: try receipt(parameters),
            rawNodeGlobalRows: [], transientPrecision: nil)
        let resources = try SPICESimulationResources(maximumLiveBytes: 1_048_576, maximumTemporaryBytes: 1_048_576,
            maximumWorkUnits: 1_048_576, maximumHashedBytes: 1_048_576)
        return try SPICEPreparationEncoding.digest(domain: "simulation-input-test", maximumBytes: 65_536, resources: resources) { encoding in
            try SPICENativeSimulation().encodeOSDI(actual, records: [record], encoding: &encoding)
        }
    }

    @Test func actualCanonicalSelectionIsRetainedAndExactBitsCommitToIdentity() throws {
        let old = try runtime()
        #expect(old.simulationParameters == nil)
        let zero = try OSDISimulationParameter(name: "value", value: .real(0))
        let minus = try OSDISimulationParameter(name: "value", value: .real(-0.0))
        let text = try OSDISimulationParameter(name: "label", value: .string("é"))
        let decomposed = try OSDISimulationParameter(name: "label", value: .string("e\u{301}"))
        let canonical = try old.retainingSimulationParameters([zero, text])
        #expect(canonical.simulationParameters?.count == 2)
        #expect(try identity([], input: old) == identity([], input: runtime([])))
        #expect(try identity([zero]) != identity([minus]))
        #expect(try identity([text]) != identity([decomposed]))
        #expect(try identity([zero, text]) != identity([text, zero]))
        #expect(try identity([zero, text], input: canonical) == identity([zero, text]))
        // A changed assertion cannot override actual receipt facts in encoding.
        #expect(try identity([zero, text], input: old) == identity([zero, text]))
    }
}
