import CircuiteFoundation
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceParsedIR
import Foundation
import OSDIContracts
import OSDIRuntime
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Actual public conditional source-flow", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageFlowOSDITests {
    private let base = NativePrescribedVoltageFlowTests()
    private func policies(_ fixture: NativeGlobalChargeOSDIFixture) -> (OSDIConstitutiveCaptureInputs, OSDISmoothRangeCaptureInputs) {
        let original = fixture.capture
        let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
        // These are the concrete PUBLIC constructors; no evaluator is supplied by the caller.
        let capture = OSDIConstitutiveCaptureInputs(preparer: factory, worker: original.worker,
            source: original.source, numericProfile: original.numericProfile, options: original.options,
            coverLimits: original.coverLimits, limits: original.limits)
        let range = OSDISmoothRangeCaptureInputs(preparer: factory, worker: original.worker,
            source: original.source, numericProfile: original.numericProfile, options: original.options)
        return (capture, range)
    }
    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture, resources: NativePrescribedVoltageFlowTests.Resources,
        parabola: Bool = false) async throws -> PreparedNativeCircuit {
        let instances: [Instance] = try [
            .init(name: "Vp", typeName: "vsource", nodes: [base.p, .ground], parameters: ["v": .real(0)], ownedBranches: [base.branch]),
            fixture.instance("NQ", nodes: parabola ? [base.d, base.x] : [base.d, .ground], capacitance: parabola ? nil : 2),
            .init(name: "Rx", typeName: "resistor", nodes: [base.x, base.p], parameters: ["r": .real(4)]),
            .init(name: "Rd", typeName: "resistor", nodes: [base.d, base.p], parameters: ["r": .real(2)]),
            fixture.instance("Nalias", nodes: [base.x, base.x])]
        let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 2,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
        let snapshot = NativeConstitutivePreparationInputs(preparer: factory, semanticProfile: fixture.snapshot.semanticProfile,
            options: fixture.snapshot.options)
        let preparer: any NativeConstitutiveCircuitPreparing = NativeCircuitPreparer()
        return try await preparer.prepare(ir: .init(nodes: [.ground, base.p, base.d, base.x], branches: [base.branch], instances: instances),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15), limits: fixture.nativeLimits,
            numericalLimits: fixture.numerical, resources: resources, osdi: runtime, constitutive: snapshot, cancellation: .init())
    }

    @Test func genuinePublicPoliciesAndBoundSourceProjectionProduceAConditionalFlowAndEscapingScopeOwnsStorage() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try await prepare(fixture, resources: resources)
            do {
                let baseline = resources.live + resources.temporary, (capture, range) = policies(fixture)
                var result: NativePrescribedVoltageFlow? = try await owner.certifyPrescribedVoltageFlow(request: base.request(),
                    capture: capture, range: range, limits: base.limits(), cancellation: .init())
                base.contains(try #require(result).endpointCharge(at: 0), 2 - exp(-0.125 / 4))
                base.contains(try #require(result).chargeRateAlmostEverywhere(at: 0), 0.25)
                var retained: NativePrescribedVoltageFlowModelScope?
                try #require(result).withScope { scope in
                    let count = scope.models.count
                    #expect(count == 2 && scope.preparation.osdiPreparationRecords.count == 2)
                    let actual = scope.models[0], alias = scope.models[1]
                    #expect(actual.preparation.instanceName == "NQ")
                    #expect(actual.initialBinding == actual.windowBinding)
                    #expect(actual.windowBinding.source == actual.smoothBinding)
                    #expect(actual.windowBinding.source.programDigest.hexadecimalValue == "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203")
                    #expect(actual.workerReference.digest.hexadecimalValue == "94e44eb3aa87677877ae792fbf285f8f1ea70da3dac57446d0ec11d39df05187")
                    #expect(actual.numericProfile.hexadecimalValue == "9aa1a0cf67ead02c06ef5fdbd10ffa78ec79a2937c5b9a6d12612569fd879e59")
                    #expect(actual.preparation.rawNodeGlobalRows.contains(nil))
                    #expect(alias.preparation.rawNodeGlobalRows.count == 2)
                    #expect(alias.preparation.rawNodeGlobalRows[0] == alias.preparation.rawNodeGlobalRows[1])
                    retained = actual
                }
                try owner.close(); result = nil
                #expect(resources.live + resources.temporary > baseline)
                #expect(retained?.preparation.instanceName == "NQ")
                retained = nil
                #expect(resources.live + resources.temporary == baseline)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func nonlinearActualChargeCannotBecomeAnAssertedAlgebraicRow() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try await prepare(fixture, resources: resources, parabola: true)
            do {
                let baseline = resources.live + resources.temporary, (capture, range) = policies(fixture)
                do {
                    _ = try await owner.certifyPrescribedVoltageFlow(request: base.request(), capture: capture,
                        range: range, limits: base.limits(), cancellation: .init())
                    Issue.record("Nonlinear original Q was replaced by the proposed algebraic zero")
                } catch NativePrescribedVoltageFlowFailure.capture(let phase, let cause) {
                    #expect(phase == .initialRoot)
                    guard case .control(let underlying) = cause,
                          case NativePrescribedVoltageChartFailure.unprovedNullRow = underlying else { throw cause }
                }
                #expect(resources.live + resources.temporary == baseline)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    private final class CancelFactory: OSDIPrecisionConstitutiveSessionPreparing {
        let native: OSDINativePrecisionSessionPreparer
        let token: CancellationToken
        let hide: Bool
        private let held = Mutex<(URL, URL)?>(nil)
        init(directory: URL, token: CancellationToken, hide: Bool) {
            native = .init(stagingParentDirectory: directory); self.token = token; self.hide = hide
        }
        func prepareConstitutiveIdentities(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent,
            source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions,
            coverLimits: OSDIPrecisionDecisionCoverLimits, limits: OSDIPrecisionConstitutiveLimits,
            coordinateQuotient: OSDIPrecisionCoordinateQuotient) async throws(OSDIPrecisionConstitutiveError) -> OSDIPrecisionSession {
            let directory = native.stagingParentDirectory
            let before: Set<URL>
            do { before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) }
            catch { throw .runtime(.host(operation: "Flow cancellation fixture", underlying: error)) }
            var session = try await native.prepareConstitutiveIdentities(program: program, worker: worker, source: source,
                numericProfile: numericProfile, options: options, coverLimits: coverLimits, limits: limits, coordinateQuotient: coordinateQuotient)
            do {
                if hide {
                    let after = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
                    let created = after.subtracting(before)
                    try #require(created.count == 1)
                    let original = try #require(created.first), moved = directory.appendingPathComponent("flow-held-helper")
                    try FileManager.default.moveItem(at: original, to: moved); held.withLock { $0 = (original, moved) }
                }
                token.cancel(); return consume session
            } catch {
                let original = OSDIError.host(operation: "Flow cancellation fixture", underlying: error)
                do { try session.close() } catch { throw .cleanup(primary: .runtime(original), secondary: error) }
                throw .runtime(original)
            }
        }
        func restore() throws {
            let paths = held.withLock { s in let result = s; s = nil; return result }
            if let paths { try FileManager.default.moveItem(at: paths.1, to: paths.0) }
        }
    }

    @Test(arguments: [false, true])
    func genuineStartupCancellationKeepsPublicPendingCleanupAndOriginalControl(hide: Bool) async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try await prepare(fixture, resources: resources)
            do {
                let baseline = resources.live + resources.temporary, token = CancellationToken(), (ordinary, range) = policies(fixture)
                let factory = CancelFactory(directory: fixture.directory, token: token, hide: hide)
                // Package-only DI deliberately cancels after a GENUINE public worker session starts.
                let capture = OSDIConstitutiveCaptureInputs(preparer: factory, evaluator: OSDINativePrecisionEvaluator(),
                    worker: ordinary.worker, source: ordinary.source, numericProfile: ordinary.numericProfile,
                    options: ordinary.options, coverLimits: ordinary.coverLimits, limits: ordinary.limits)
                var pending: OSDIConstitutiveCaptureCleanup?
                do {
                    _ = try await owner.certifyPrescribedVoltageFlow(request: base.request(), capture: capture,
                        range: range, limits: base.limits(), cancellation: token)
                    Issue.record("Cancelled Flow published")
                } catch NativePrescribedVoltageFlowFailure.cancelled { #expect(!hide) }
                catch NativePrescribedVoltageFlowFailure.capture(let phase, .cleanupPending(let primary, let secondary, let cleanup)) {
                    #expect(hide && phase == .initialValues && secondary != nil)
                    guard case .cleanup(primary: .control(let original), secondary: _) = primary,
                          case NativeConstitutiveInspection.Failure.cancelled = original else { throw primary }
                    pending = cleanup
                }
                #expect(token.isCancelled)
                if hide {
                    #expect(pending != nil && resources.live + resources.temporary > baseline)
                    try factory.restore(); try pending?.close(); try pending?.close(); pending = nil
                }
                #expect(resources.live + resources.temporary == baseline)
                let (captureAgain, _) = policies(fixture)
                let reused = try await owner.certifyPrescribedVoltageFlow(request: base.request(), capture: captureAgain,
                    range: range, limits: base.limits(), cancellation: .init())
                base.contains(try reused.endpointCharge(at: 0), 1)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
