import CoreSpiceDiodeContracts
@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceIR
import CoreSpiceDevices
import Testing

extension PreparedNativeExecutionTests {
    @Test func resolvedDiodeHasCheckedNativePreparation() async throws {
        let resources = SourceBoundaryTestResources()
        let retained = try await input("D3\n.temp 42\n.model dm D(m=.4)\nV1 a 0 1\nD1 a 0 dm area=3 m=2\n.op\n.end\n",
                                       resources: resources, diodeProfile: .coreDiodeV1)
        let baseline = resources.used(.liveOwnedBytes)
        #expect(retained.circuit.instances.first { $0.name == "d1" }?.diode?.resolved.input.multiplicity.value == 2)
        do {
            let prepared = try SPICENativeSimulation().prepare(retained,
                limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16_000_000,
                    diodePreparationLimits: try .init(maximumRetainedBytes: 65536, maximumTemporaryBytes: 4096,
                        maximumWorkUnits: 1000), diodeAnalyses: [.dc]))
            let receipts = prepared.record.circuitPreparation.diodePreparationReceipts
            #expect(receipts.count == 1 && receipts[0].coldSetupCount == 1)
            #expect(receipts[0].identity.resolved.input.multiplicity.value == 2)
            #expect(receipts[0].identity.effectiveTemperature.value == 315.15)
            let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
            #expect(output.waveform.pointCount == 1)
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }
    @Test func diodeDiagnosticRetainsAndReleasesFrontendAccounting() async throws {
        let resources = SourceBoundaryTestResources()
        try await inspectDiagnostic(resources)
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }
    private func inspectDiagnostic(_ resources: SourceBoundaryTestResources) async throws {
        var retainedError: SPICESimulationPreparationError?
        do { _ = try await input("D3\n.model dm D(js=0)\nD1 a 0 dm\n.op\n.end\n", resources: resources, diodeProfile: .coreDiodeV1) }
        catch let failure as SPICESimulationPreparationError { retainedError = failure }
        guard case .diodeResolution(let diagnostic, _, let reservation) = retainedError else {
            Issue.record("Lost structured diagnostic and owner"); return
        }
        #expect(diagnostic.cause == .schema(.unsupportedParameter(name: "js", role: .model)))
        #expect(diagnostic.assignment?.location?.line == 2)
        let held = try #require(reservation)
        #expect(resources.used(.liveOwnedBytes) >= held.byteCount)
        withExtendedLifetime(retainedError) { }
    }

    @Test func resolvedDiodeBatchFailureReleasesPreparationStorage() async throws {
        let resources = SourceBoundaryTestResources()
        let retained = try await input("batch\n.model good D(is=1e-14)\n.model bad D(rs=10)\nV1 a 0 .2\nR1 a b 1k\nD1 a 0 good\nD2 b 0 bad\n.op\n.end\n",
            resources: resources, diodeProfile: .coreDiodeV1)
        let baseline = resources.used(.liveOwnedBytes)
        let work = resources.work(.retainedElements)
        do {
            _ = try SPICENativeSimulation().prepare(retained,
                limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16_000_000,
                    diodePreparationLimits: try .init(maximumRetainedBytes: 65536, maximumTemporaryBytes: 4096,
                        maximumWorkUnits: 1000), diodeAnalyses: [.dc]))
            Issue.record("Unsupported second diode published a partial prepared circuit")
        } catch SPICENativePreparationError.diodePreparation(.schema(.unsupportedFeature(.seriesResistance))) {}
        #expect(resources.work(.retainedElements) >= work + 32)
        #expect(resources.used(.liveOwnedBytes) == baseline)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func rawDiodeCannotEnterNativeRegistryBypass() throws {
        let resources = SourceBoundaryTestResources()
        var registry = DeviceRegistry.standard()
        registry.register(RawDiodeBypassCounterexample())
        let circuit = CircuitIR(nodes: [.init(id: 1)], branches: [], instances: [
            .init(name: "D1", typeName: "diode", nodes: [.init(id: 1), .ground], parameters: ["is": .real(1e-14)])])
        do {
            _ = try NativeCircuitPreparer().prepare(ir: circuit, registry: registry, operatingConditions: .nominal,
                limits: .init(maximumDeviceCount: 10, maximumMatrixDimension: 10, maximumAllocationBytes: 1_000_000),
                numericalLimits: .init(maximumAcceptedSteps: 100, maximumSolveAttempts: 100,
                    maximumNewtonIterations: 1000, maximumSavedScalars: 1000, maximumMatrixDimension: 10,
                    maximumWorkUnits: 100000, maximumBreakpoints: 100), resources: resources)
            Issue.record("Raw diode entered the native registry path")
        } catch SPICENativePreparationError.diodePreparation(.missingPreparedReceipt) {}
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.used(.temporaryBytes) == 0)
    }
    @Test func resolvedMOSAndDiodeShareOneCheckedNativeBatch() async throws {
        let resources = SourceBoundaryTestResources()
        let retained = try await input("mixed\n.model NM NMOS(level=1 vto=.4 kp=120u)\n.model dm D(is=1e-14)\nV1 d 0 .3\nV2 g 0 .7\nM1 d g 0 0 NM w=1u l=1u\nD1 d 0 dm\n.op\n.end\n",
            resources: resources, diodeProfile: .coreDiodeV1)
        let baseline = resources.used(.liveOwnedBytes)
        do {
            let base = try mosLimits(capabilities: [.dc])
            let owner = try SPICENativeSimulation().prepare(retained,
                limits: .init(maximumDeviceCount: base.maximumDeviceCount,
                    maximumMatrixDimension: base.maximumMatrixDimension, maximumAllocationBytes: base.maximumAllocationBytes,
                    mosPreparationLimits: base.mosPreparationLimits, mosPreparationConditions: base.mosPreparationConditions,
                    diodePreparationLimits: try .init(maximumRetainedBytes: 65536, maximumTemporaryBytes: 4096,
                        maximumWorkUnits: 1000), diodeAnalyses: [.dc]))
            let facts = owner.record.circuitPreparation
            #expect(facts.mosPreparationReceipts.count == 1 && facts.diodePreparationReceipts.count == 1)
            #expect(facts.mosPreparationReceipts[0].coldSetupCount == 1 && facts.diodePreparationReceipts[0].coldSetupCount == 1)
            let output = try await SPICENativeSimulation().execute(owner, cancellation: .init())
            #expect(output.waveform.pointCount == 1)
        }
        #expect(resources.used(.liveOwnedBytes) == baseline && resources.used(.temporaryBytes) == 0)
    }

}

private struct RawDiodeBypassCounterexample: DeviceDescriptor {
    let typeName = "diode"
    let portNames = ["anode", "cathode"]
    let parameterDescriptors: [ParameterDescriptor] = []
    struct ReachedRegistry: Error {}
    func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        throw ReachedRegistry()
    }
}
