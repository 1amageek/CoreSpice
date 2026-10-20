import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceDevices
import CoreSpiceIR
import Foundation
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpiceOSDI

@Suite("Actual-bound smooth spatial range", .timeLimit(.minutes(2)))
struct OSDISmoothRangeCaptureTests {
    private enum Model: Equatable { case linear, parabola, time, nonsmooth }
    private struct Factory: OSDIPrecisionRangeSessionPreparing {
        let native: OSDINativePrecisionSessionPreparer
        var replacement: OSDIPrecisionProgram? = nil
        var profile: ContentDigest? = nil
        func prepareRange(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent,
            source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions)
            async throws(OSDIError) -> OSDIPrecisionSession {
            try await native.prepareRange(program: replacement ?? program, worker: worker, source: source,
                numericProfile: profile ?? numericProfile, options: options)
        }
    }
    private func external(_ name: String) throws -> String {
        try #require(ProcessInfo.processInfo.environment[name], "Missing qualified smooth range fixture: \(name)")
    }
    private func context() throws -> OSDIPrecisionContext { try .init(mode: .transient, timeHigh: 0.25, timeLow: 0) }
    private func withDevices(_ model: Model = .linear, nodes: [Node], count: Int = 1,
        control: OSDIConstitutiveTestControl,
        _ body: ([any BoundDevice], OSDISmoothRangeCaptureInputs) async throws -> Void) async throws {
        let path: String, digest: String, descriptor: String
        switch model {
        case .linear:
            path = try external("CORESPICE_GLOBAL_CHARGE_LINEAR_LIBRARY")
            digest = "25f3f51c385252ce34876ca990aa6e932bf7a4c1948237b0100d03749158d846"; descriptor = "linear_rc"
        case .parabola:
            path = try external("CORESPICE_GLOBAL_CHARGE_PARABOLA_LIBRARY")
            digest = "364a8156c02330c7fe710cadcc468617f6fa4c7f0183db1da6cf30806f08a927"; descriptor = "global_charge_parabola"
        case .time:
            path = try external("CORESPICE_SMOOTH_TIME_LIBRARY")
            digest = "0264f0d0e35850efb1626bcf64710522e3a75686d03b1d86a9b1439266f9d56d"; descriptor = "precision_context"
        case .nonsmooth:
            path = try external("CORESPICE_SMOOTH_NONSMOOTH_LIBRARY")
            digest = "2abf2a2f59f8a40342fc8a8726f83d70c5ffdc8bf5e11f09eeb656357319927f"; descriptor = "global_charge_nonsmooth"
        }
        let fixture = try OSDIAdapterFixture(library: .init(id: "smooth-source", path: path,
            sha256: digest, descriptorIndex: 0, descriptorName: descriptor))
        do {
            try FileManager.default.copyItem(atPath: external("OSDI_PRECISION_WORKER"),
                toPath: fixture.directory.appendingPathComponent("worker").path)
            let worker = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                .init(location: ArtifactLocation(workspaceRelativePath: "worker"), role: .input, kind: .model, format: .raw),
                relativeTo: fixture.directory)
            try #require(worker.digest.hexadecimalValue == "94e44eb3aa87677877ae792fbf285f8f1ea70da3dac57446d0ec11d39df05187")
            let intent = try ArtifactAccessIntent(expectedReference: worker,
                availability: .local(artifactID: worker.id, rootID: fixture.provider.root.rootID,
                    relativePath: ArtifactRelativePath(segments: ["worker"])), operation: .read,
                budget: .init(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            let native = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
            let policy = try OSDIPrecisionOptions(maximumProgramBytes: 1_048_576, maximumMappingBytes: 16_777_216,
                arenaBytes: 16_777_216, maximumWorkUnits: 100_000_000, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
                startupTimeoutNanoseconds: 2_000_000_000, evaluationTimeoutNanoseconds: 2_000_000_000,
                cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
            let semantic = try ContentDigest(algorithm: .sha256, hexadecimalValue: external("CORESPICE_GLOBAL_CHARGE_SEMANTIC_SHA256"))
            let numeric = try ContentDigest(algorithm: .sha256, hexadecimalValue: external("OSDI_PRECISION_NUMERIC_PROFILE_SHA256"))
            try #require(semantic.hexadecimalValue == "a85f38191b22ccf3b084f0892ee0fa51752d37f0defa6b62dee929935be35104")
            try #require(numeric.hexadecimalValue == "9aa1a0cf67ead02c06ef5fdbd10ffa78ec79a2937c5b9a6d12612569fd879e59")
            let inputs = OSDISmoothRangeCaptureInputs(preparer: native, worker: intent,
                source: fixture.provider.root, numericProfile: numeric, options: policy)
            let instances = try (0..<count).map { index in
                try fixture.instance("N\(index)", nodes: nodes, modelParameters: model == .linear ? [
                    .init(name: "conductance", scope: .model, value: .real(0)),
                    .init(name: "capacitance", scope: .model, value: .real(Double(index + 1)))] : [])
            }
            let preparer: any OSDIConstitutiveCircuitPreparing = OSDICircuitPreparer()
            var prepared = try await preparer.prepare(ir: .init(nodes: Array(Set(nodes)).sorted { $0.id < $1.id }, branches: [], instances: instances),
                operatingConditions: .nominal, provider: fixture.provider,
                loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
                evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 64,
                    maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: count,
                maximumAdapterBytes: 268_435_456, transientPrecision: nil,
                constitutiveSnapshot: .init(preparer: native, semanticProfile: semantic, options: policy, control: control))
            do {
                var binding = fixture.context(CircuitTopology(ir: prepared.circuit)), devices: [any BoundDevice] = []
                for index in 0..<count {
                    guard let pending = try prepared.takeDevice(at: index) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                    devices.append(try pending.bind(context: &binding))
                }
                try await body(devices, inputs)
            } catch { try prepared.close(); throw error }
            try prepared.close()
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }
    private func observe<Result>(_ capture: inout OSDISmoothRangeCapture, lower: [Double], upper: [Double],
        _ body: (OSDIPrecisionRangeEvaluationView, OSDIConstitutiveInventoryView, OSDISmoothRangeScope) throws -> Result) throws -> Result {
        let zero = [Double](repeating: 0, count: lower.count)
        return try capture.withCheckedRange(lowerHigh: lower.span, lowerLow: zero.span, upperHigh: upper.span,
            upperLow: zero.span, lowerContext: context(), upperContext: context(), precisionBits: 192, body)
    }

    @Test func actualLinearRawPlanesAndExactScopeSurviveCloseForGroundAndAliases() async throws {
        for nodes in [[Node(id: 1), Node(id: 2)], [Node(id: 1), .ground], [Node(id: 1), Node(id: 1)]] {
            let control = OSDIConstitutiveTestControl()
            var retained: OSDISmoothRangeScope?
            try await withDevices(nodes: nodes, control: control) { devices, inputs in
                let candidate = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: devices[0])
                let program = try #require(candidate)
                let expectedContext = try context()
                var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
                do {
                    retained = try observe(&capture, lower: [-1, -1], upper: [1, 1]) { view, inventory, scope in
                        #expect(view.cLower.count == 4 && view.cUpper.count == 4 && !view.programHasTimeInput)
                        for (i, expected) in [1.0, -1, -1, 1].enumerated() {
                            #expect(view.cLower[i] <= expected && view.cUpper[i] >= expected)
                            #expect(view.cUpper[i] - view.cLower[i] < 1e-12)
                        }
                        #expect(inventory.rawGlobal.count == 2 && inventory.activeGlobal.count == 2)
                        #expect(inventory.rawGlobal[0] == 0)
                        #expect(inventory.rawGlobal[1] == (nodes[1] == .ground ? nil : nodes[0] == nodes[1] ? 0 : 1))
                        #expect(scope.source == OSDIPrecisionChartBinding(program: program))
                        #expect(scope.workerReference == inputs.worker.expectedReference && scope.numericProfile == inputs.numericProfile)
                        #expect(scope.options == inputs.options && scope.lowerContext == expectedContext && scope.upperContext == expectedContext)
                        scope.withCoordinates { lh, ll, uh, ul in
                            for i in 0..<2 { #expect(lh[i] == -1 && ll[i] == 0 && uh[i] == 1 && ul[i] == 0) }
                        }
                        return scope
                    }
                    let before = control.counters.work
                    try observe(&capture, lower: [0, 0], upper: [0.5, 0.5]) { view, _, _ in #expect(view.requestSequence == 2) }
                    #expect(control.counters.work - before < Int(inputs.options.maximumWorkUnits))
                } catch { try capture.close(); throw error }
                try capture.close(); try capture.close()
            }
            #expect(control.counters.live > 0)
            retained?.withInventory { inventory in #expect(inventory.rawGlobal.count == 2) }
            retained = nil
            #expect(control.counters.live == 0)
        }
    }

    @Test func nonlinearSourceSpatialDerivativeIsActualV2NotAnIdentityRootPlane() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(.parabola, nodes: [Node(id: 1), Node(id: 2)], control: control) { devices, inputs in
            var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
            do {
                try observe(&capture, lower: [-1, -1], upper: [1, 1]) { view, _, scope in
                    #expect(view.cLower[0] <= 1 && view.cUpper[0] >= 1)
                    #expect(view.cLower[2] <= -2 && view.cUpper[2] >= 2)
                    #expect(view.cLower[1] == 0 && view.cUpper[1] == 0 && view.cLower[3] == 0 && view.cUpper[3] == 0)
                    #expect(scope.usedPrecisionBits >= 192)
                }
            } catch { try capture.close(); throw error }
            try capture.close()
        }
        #expect(control.counters.live == 0)
    }

    @Test func realReturnedSetupProfileAndPolicyMismatchesNeverPublishAnOwner() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(nodes: [Node(id: 1), .ground], count: 2, control: control) { devices, inputs in
            let candidate = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: devices[1])
            let other = try #require(candidate)
            for factory in [Factory(native: .init(), replacement: other),
                Factory(native: .init(), profile: try .init(algorithm: .sha256, hexadecimalValue: String(repeating: "0", count: 64)))] {
                let changed = OSDISmoothRangeCaptureInputs(preparer: factory, worker: inputs.worker, source: inputs.source,
                    numericProfile: inputs.numericProfile, options: inputs.options)
                let baseline = control.counters.live
                do { var wrong = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: changed)
                    try wrong.close(); Issue.record("Different actual returned setup/profile admitted") }
                catch OSDISmoothRangeFailure.invalidBinding {}
                #expect(control.counters.live == baseline)
            }
            let actual = try #require(devices[0] as? BoundOSDIDevice)
            let missing = BoundOSDIDevice(instance: actual.instance, owner: actual.owner, mapping: actual.mapping,
                residualNoiseSources: actual.residualNoiseSources, hasReactiveResidual: actual.hasReactiveResidual,
                transientPrecisionReceipt: nil)
            do { var wrong = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: missing, inputs: inputs)
                try wrong.close(); Issue.record("Missing snapshot admitted") }
            catch OSDISmoothRangeFailure.missingSnapshot {}
            let policy = try OSDIPrecisionOptions(maximumProgramBytes: inputs.options.maximumProgramBytes,
                maximumMappingBytes: inputs.options.maximumMappingBytes, arenaBytes: inputs.options.arenaBytes,
                maximumWorkUnits: 1, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
                startupTimeoutNanoseconds: inputs.options.startupTimeoutNanoseconds,
                evaluationTimeoutNanoseconds: inputs.options.evaluationTimeoutNanoseconds,
                cleanupTimeoutNanoseconds: inputs.options.cleanupTimeoutNanoseconds, pollNanoseconds: inputs.options.pollNanoseconds)
            let changed = OSDISmoothRangeCaptureInputs(preparer: inputs.preparer, worker: inputs.worker,
                source: inputs.source, numericProfile: inputs.numericProfile, options: policy)
            do { var wrong = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: changed)
                try wrong.close(); Issue.record("Different snapshot/runtime options admitted") }
            catch OSDISmoothRangeFailure.invalidBinding {}
            var binding = BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0], matrixDimension: 1)
            let native = try CapacitorDescriptor().bind(instance: .init(name: "Cnative", typeName: "capacitor",
                nodes: [Node(id: 1), .ground], parameters: ["c": .real(1)]), context: &binding)
            do { var wrong = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: native, inputs: inputs)
                try wrong.close(); Issue.record("A non-OSDI producer acquired source authority") }
            catch OSDISmoothRangeFailure.invalidBinding {}
        }
        #expect(control.counters.live == 0)
    }

    @Test func helperStorageAndCancellationInsideActualResultRefundAllAdmission() async throws {
        let limited = OSDIConstitutiveTestControl(storage: 2_097_152)
        try await withDevices(nodes: [Node(id: 1), .ground], control: limited) { devices, inputs in
            let baseline = limited.counters.live
            do { var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
                try capture.close(); Issue.record("Unadmitted helper mapping/arena started") }
            catch OSDIConstitutiveTestControl.Refusal.storage {}
            #expect(limited.counters.live == baseline)
        }
        #expect(limited.counters.live == 0)
        let cancelled = OSDIConstitutiveTestControl()
        try await withDevices(nodes: [Node(id: 1), .ground], control: cancelled) { devices, inputs in
            let baseline = cancelled.counters.live
            do {
                var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
                do { try observe(&capture, lower: [0, 0], upper: [1, 0]) { _, _, _ in cancelled.cancel() }
                    Issue.record("Cancellation at actual callback published success") }
                catch OSDISmoothRangeFailure.control(let cause) { #expect(cause as? OSDIConstitutiveTestControl.Refusal == .cancelled) }
                try capture.close()
            }
            // Close refunds helper storage; the capture's immutable inventory lives until final release.
            #expect(cancelled.counters.live == baseline)
        }
        #expect(cancelled.counters.live == 0)
    }

    @Test func callbackFailureCancellationAndSharedAllowanceCloseWithoutChangingNativeOwner() async throws {
        let control = OSDIConstitutiveTestControl(work: 101_000_000)
        try await withDevices(nodes: [Node(id: 1), .ground], count: 2, control: control) { devices, inputs in
            let baseline = control.counters.live
            do {
                var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
                do { try observe(&capture, lower: [0, 0], upper: [1, 0]) { _, _, _ in throw OSDIConstitutiveTestControl.Refusal.storage }
                    Issue.record("Failed caller publication succeeded") }
                catch OSDISmoothRangeFailure.control(let cause) { #expect(cause as? OSDIConstitutiveTestControl.Refusal == .storage) }
                try capture.close()
            }
            #expect(control.counters.live == baseline)
            do { var second = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[1], inputs: inputs)
                try second.close(); Issue.record("Second scheduled allowance reset shared work") }
            catch OSDIConstitutiveTestControl.Refusal.work {}
            #expect(control.counters.live == baseline)
            control.cancel()
            do { var second = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
                try second.close(); Issue.record("Cancelled helper started") }
            catch OSDIConstitutiveTestControl.Refusal.cancelled {}
        }
        #expect(control.counters.live == 0)
    }

    @Test func actualExplicitTimeSourceCannotPublishSpatialOnlyAuthority() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(.time, nodes: [Node(id: 1)], control: control) { devices, inputs in
            let candidate = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: devices[0])
            let program = try #require(candidate)
            #expect(program.programDigest.hexadecimalValue == "eea8d2ce12b0bbf5395b084cd73263fabcb7d8f9c554adc4e48ab949e817df28")
            let baseline = control.counters.live
            var published = false
            do {
                var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
                do { try observe(&capture, lower: [0], upper: [1]) { _, _, _ in published = true }
                    Issue.record("Time input published Qt-free derivative authority") }
                catch OSDISmoothRangeFailure.explicitTimeInput {}
                try capture.close()
            }
            #expect(!published && control.counters.live == baseline)
        }
        #expect(control.counters.live == 0)
    }

    @Test func actualCleanupFailureKeepsAdmissionUntilExactPendingOwnerRetry() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(nodes: [Node(id: 1), .ground], control: control) { devices, inputs in
            let native = try #require(inputs.preparer as? OSDINativePrecisionSessionPreparer)
            let directory = native.stagingParentDirectory
            let before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
            let after = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            let added = after.subtracting(before)
            try #require(added.count == 1)
            let original = try #require(added.first), held = directory.appendingPathComponent("held-smooth-helper")
            try FileManager.default.moveItem(at: original, to: held)
            let live = control.counters.live
            var pending: OSDIConstitutiveCaptureCleanup?
            do { try capture.close(); Issue.record("Missing actual helper directory cleanup succeeded") }
            catch OSDISmoothRangeFailure.cleanupPending(_, _, let owner) { pending = owner }
            #expect(pending != nil && control.counters.live == live)
            try FileManager.default.moveItem(at: held, to: original)
            try pending?.close(); try pending?.close()
            #expect(control.counters.live < live)
            pending = nil
            try capture.close()
        }
        #expect(control.counters.live == 0)
    }

    @Test func actualNonsmoothChargeRefusesCrossingBoxButAdmitsPositiveSmoothBox() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(.nonsmooth, nodes: [Node(id: 1), .ground], control: control) { devices, inputs in
            let candidate = try OSDIConstitutiveBoundDeviceAccess.snapshot(of: devices[0])
            let program = try #require(candidate)
            #expect(program.programDigest.hexadecimalValue == "a7ffeffa20274b1a01d7f6fa2c9120dac70a00fa21ab621829892a8628bf23ae")
            var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareSmoothRangeCapture(of: devices[0], inputs: inputs)
            try observe(&capture, lower: [0.5, 0], upper: [1, 0]) { view, _, _ in
                #expect(view.cLower[0] <= 1 && view.cUpper[0] >= 1)
            }
            var published = false
            do { try observe(&capture, lower: [-1, 0], upper: [1, 0]) { _, _, _ in published = true }
                Issue.record("Charge derivative crossing abs face admitted") }
            catch OSDISmoothRangeFailure.runtime(.precision(let issue)) { #expect(issue.code == .nonsmooth) }
            try capture.close()
            #expect(!published)
        }
        #expect(control.counters.live == 0)
    }
}
