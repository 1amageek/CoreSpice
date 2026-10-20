import Testing
import Foundation
import Darwin
import Synchronization
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceOSDITestSupport
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDIContracts
import OSDIContracts
import OSDIRuntime
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDISimulationParameterPreparationTests {
    @Test func canonicalSelectionDistinguishesOmissionFromAnEmptyAssertion() throws {
        let real = try OSDISimulationParameter(name: "tnom", value: .real(300.15))
        let text = try OSDISimulationParameter(name: "label", value: .string("source"))
        #expect(try OSDICircuitPreparer.resolveSimulationParameters(nil, nil).isEmpty)
        let values = [real, text]
        #expect(try OSDICircuitPreparer.resolveSimulationParameters(values, nil) == values)
        #expect(try OSDICircuitPreparer.resolveSimulationParameters(nil, values) == values)
        #expect(try OSDICircuitPreparer.resolveSimulationParameters(values, values) == values)
        for other in [[], [text, real], [real], [try OSDISimulationParameter(name: "tnom", value: .string("300.15")), text]] {
            do {
                _ = try OSDICircuitPreparer.resolveSimulationParameters(values, other)
                Issue.record("Conflicting explicit selection was accepted")
            } catch { guard case .conditionsMismatch = error else { throw error } }
        }
        let plus = [try OSDISimulationParameter(name: "value", value: .real(0))]
        let minus = [try OSDISimulationParameter(name: "value", value: .real(-0.0))]
        do { _ = try OSDICircuitPreparer.resolveSimulationParameters(plus, minus); Issue.record("Signed zero conflict lost") }
        catch { guard case .conditionsMismatch = error else { throw error } }
    }

    private final class CountingProvider: OSDILibraryProviding {
        let calls = Mutex(0)
        func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
            calls.withLock { $0 += 1 }
            throw .identityMismatch
        }
    }

    @Test func conflictAndOrdinaryValidationCapacityRefuseBeforeAcquisition() async throws {
        let provider = CountingProvider()
        let reference = try ArtifactReference(digest: ContentDigest(algorithm: .sha256,
            hexadecimalValue: String(repeating: "a", count: 64)), byteCount: 1,
            descriptor: ArtifactDescriptor(role: .input, kind: .model, format: .raw))
        let binding = try OSDIModelBinding(modelName: "model", artifact: reference, descriptorIndex: 0,
            expectedDescriptorName: "model", modelParameters: [])
        let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])
        let ir = CircuitIR(nodes: [Node(id: 1)], branches: [], instances: [Instance(name: "N1", typeName: "osdi",
            nodes: [Node(id: 1)], parameters: [:], osdi: .resolved(resolved))])
        let selected = [try OSDISimulationParameter(name: "tnom", value: .real(300.15))]
        let precision = try OSDIPrecisionOptions(maximumProgramBytes: 1_048_576, maximumMappingBytes: 16_777_216,
            arenaBytes: 16_777_216, maximumWorkUnits: 100_000_000, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
            startupTimeoutNanoseconds: 2_000_000_000, evaluationTimeoutNanoseconds: 2_000_000_000,
            cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
        let control = OSDIConstitutiveTestControl()
        let snapshot = OSDIConstitutiveSnapshotInputs(preparer: OSDINativePrecisionSessionPreparer(
            stagingParentDirectory: FileManager.default.temporaryDirectory),
            semanticProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "b", count: 64)),
            options: precision, control: control, simulationParameters: selected)
        let load = try OSDILoadLimits(maximumDescriptors: 1, maximumMetadataBytes: 4096, maximumStorageBytes: 4096)
        let limits = try OSDIEvaluationLimits(maximumWorkspaceBytes: 4096, maximumDiagnosticCount: 1,
            maximumDiagnosticBytes: 4096, maximumStringBytes: 4096)
        do {
            _ = try await OSDICircuitPreparer().prepare(ir: ir, operatingConditions: .nominal, provider: provider,
                loadLimits: load, evaluationLimits: limits, maximumInstanceCount: 1, maximumAdapterBytes: 1_048_576,
                transientPrecision: nil, constitutiveSnapshot: snapshot, simulationParameters: [])
            Issue.record("Conflicting empty selection reached acquisition")
        } catch { guard case OSDIAdapterFailure.conditionsMismatch = error else { throw error } }
        #expect(provider.calls.withLock { $0 } == 0)
        #expect(control.counters.live == 0)
        let legacyBudget = try OSDIAdapterCapacity.initial(ir: ir)
        do {
            _ = try await OSDICircuitPreparer().prepare(ir: ir, operatingConditions: .nominal, provider: provider,
                loadLimits: load, evaluationLimits: limits, maximumInstanceCount: 1, maximumAdapterBytes: legacyBudget,
                simulationParameters: selected)
            Issue.record("Unadmitted validation table reached acquisition")
        } catch { guard case OSDIAdapterFailure.capacityExceeded = error else { throw error } }
        #expect(provider.calls.withLock { $0 } == 0)
    }

    private struct LegacyPreparer: OSDICircuitPreparing {
        func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
            provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
            evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
            maximumAdapterBytes: UInt64) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
            throw .invalidTopology
        }
    }

    @Test func legacyProtocolDefaultRefusesNonemptyRatherThanDroppingIt() async throws {
        let legacy: any OSDICircuitPreparing = LegacyPreparer()
        let load = try OSDILoadLimits(maximumDescriptors: 1, maximumMetadataBytes: 4096, maximumStorageBytes: 4096)
        let limits = try OSDIEvaluationLimits(maximumWorkspaceBytes: 4096, maximumDiagnosticCount: 1,
            maximumDiagnosticBytes: 4096, maximumStringBytes: 4096)
        for parameters in [[], [try OSDISimulationParameter(name: "tnom", value: .real(300.15))]] {
            do {
                _ = try await legacy.prepare(ir: CircuitIR(nodes: [], branches: [], instances: []),
                    operatingConditions: .nominal, provider: CountingProvider(), loadLimits: load,
                    evaluationLimits: limits, maximumInstanceCount: 1, maximumAdapterBytes: 1_048_576,
                    transientPrecision: nil, simulationParameters: parameters)
                Issue.record("Legacy test preparer unexpectedly returned")
            } catch {
                if parameters.isEmpty { guard case .invalidTopology = error else { throw error } }
                else { guard case .unsupportedAnalysis = error else { throw error } }
            }
        }
    }

    @Test func actualNumericAndStringSetupMatchesIndependentSDKAndLegacyRerun() async throws {
        // Extend the SDK's ABI transport fixture, not any official physical equation.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sdk = package.appendingPathComponent(".build/checkouts/swift-osdi")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-simulation-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Transport fixture cleanup failed: \(error)") } }
        var source = try String(contentsOf: sdk.appendingPathComponent("Tests/OSDIEvaluationTests/Fixtures/protocol.c"), encoding: .utf8)
        let originalSetup = "(void)handle;(void)model;(void)paras;*info=(OsdiInitInfo){0};"
        try #require(source.components(separatedBy: originalSetup).count == 2)
        source = source.replacingOccurrences(of: originalSetup, with: """
        (void)handle;*(double *)model=0;
        for(unsigned i=0;paras->names[i];++i) if(!strcmp(paras->names[i],"gain")) *(double *)model+=paras->vals[i];
        for(unsigned i=0;paras->names_str[i];++i) if(!strcmp(paras->names_str[i],"label")&&!strcmp(paras->vals_str[i],"retained")) *(double *)model+=32;
        *info=(OsdiInitInfo){0};
        """)
        let originalResidual = "=input+info->prev_state[indices[0]];"
        try #require(source.components(separatedBy: originalResidual).count == 2)
        source = source.replacingOccurrences(of: originalResidual, with: "=input+info->prev_state[indices[0]]+*(double *)model;")
        let input = directory.appendingPathComponent("simulation.c"), output = directory.appendingPathComponent("simulation.dylib")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-dynamiclib", "-O2", "-DPROTOCOL_MODE=0", "-I", sdk.appendingPathComponent("Sources/COSDI/ABI").path, input.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("Simulation fixture compiler timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw error }
        try #require(process.terminationStatus == 0)
        let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
            ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "simulation.dylib"), role: .input, kind: .model, format: .raw), relativeTo: directory)
        let fixture = try OSDIAdapterFixture(library: .init(id: "simulation-input", path: output.path,
            sha256: reference.digest.hexadecimalValue, descriptorIndex: 0, descriptorName: "protocol_transport"))
        do throws(any Error) {
            let parameters = [try OSDISimulationParameter(name: "gain", value: .real(17.25)),
                              try OSDISimulationParameter(name: "label", value: .string("retained"))]
            let load = try OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 16_777_216)
            let limits = try OSDIEvaluationLimits(maximumWorkspaceBytes: 16_777_216, maximumDiagnosticCount: 64,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536)
            let instance = try fixture.instance("Nsim", nodes: [Node(id: 1)], previousState: [3, 7])
            let ir = CircuitIR(nodes: [Node(id: 1)], branches: [], instances: [instance])
            for selected in [parameters, [], parameters] {
                let library = try await fixture.provider.load(reference: fixture.reference, limits: load)
                do {
                    var native = try OSDINativeModelPreparer().prepare(library: library, descriptorIndex: 0,
                        options: OSDIPreparationOptions(parameters: [], simulationParameters: selected,
                            temperatureKelvin: 298.15, connectedTerminalCount: 1, limits: limits))
                    do {
                        let x = [0.5], previous = [3.0, 7.0]
                        let expected = try OSDINativeModelEvaluator().evaluate(model: &native,
                            context: OSDIEvaluationContext(mode: .dc, timeSeconds: 0),
                            unknowns: x.span, previousState: previous.span) { $0.f[0] }
                        #expect(expected == (selected.isEmpty ? 3.5 : 52.75))
                        var prepared = try await OSDICircuitPreparer().prepare(ir: ir,
                            operatingConditions: OperatingConditions(temperatureKelvin: 298.15), provider: fixture.provider,
                            loadLimits: load, evaluationLimits: limits, maximumInstanceCount: 1, maximumAdapterBytes: 16_777_216,
                            simulationParameters: selected)
                        do {
                            let receipt = try #require(prepared.receipts.first)
                            #expect(OSDIPreparationReceipt.simulationParametersEqual(receipt.simulationParameters, selected))
                            #expect(receipt.effectiveTemperatureKelvin == 298.15)
                            let topology = CircuitTopology(ir: prepared.circuit)
                            var binding = BindingContext(variableMap: topology.variableMap, matrixDimension: topology.matrixSize,
                                operatingConditions: try OperatingConditions(temperatureKelvin: 298.15),
                                stampIndexResolver: { row, col in row * topology.matrixSize + col })
                            guard let pending = try prepared.takeDevice(at: 0) else {
                                throw OSDIAdapterFixture.FixtureFailure.missingOwner
                            }
                            let bound = try pending.bind(context: &binding)
                            let physical = try #require(bound as? any DCPhysicalResidualContributing)
                            var actual = 0.0
                            try physical.accumulatePhysicalResidual(state: SolutionState(variables: x, variableMap: topology.variableMap)) { _, value in actual += value }
                            #expect(actual == expected)
                        } catch { try prepared.close(); throw error }
                        try prepared.close()
                    } catch { native.close(); throw error }
                    native.close()
                } catch { try library.close(); throw error }
                try library.close()
            }
            do {
                _ = try await OSDICircuitPreparer().prepare(ir: ir,
                    operatingConditions: OperatingConditions(temperatureKelvin: 298.15), provider: fixture.provider,
                    loadLimits: load, evaluationLimits: limits, maximumInstanceCount: 1, maximumAdapterBytes: 16_777_216,
                    simulationParameters: [parameters[0], parameters[0]])
                Issue.record("Duplicate simulation input was silently deduplicated")
            } catch OSDIAdapterFailure.runtime(.contract(.invalidParameterValue)) {}
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }
}
