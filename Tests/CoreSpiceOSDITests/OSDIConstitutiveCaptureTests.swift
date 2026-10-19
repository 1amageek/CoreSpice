import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import Foundation
import OSDIContracts
import OSDIRuntime
import Synchronization
import Testing
@testable import CoreSpiceOSDI

@Suite("Actual-bound conditional identity capture", .timeLimit(.minutes(1)))
struct OSDIConstitutiveCaptureTests {
    private final class Factory: OSDIPrecisionSessionPreparing, OSDIPrecisionConstitutiveSessionPreparing {
        struct Counts { var snapshots = 0; var legacySnapshots = 0; var points = 0; var identities = 0 }
        private let state = Mutex(Counts())
        let native: OSDINativePrecisionSessionPreparer
        let returnedNumericProfile: ContentDigest?
        var counts: Counts { state.withLock { $0 } }
        init(directory: URL, returnedNumericProfile: ContentDigest? = nil) {
            native = OSDINativePrecisionSessionPreparer(stagingParentDirectory: directory)
            self.returnedNumericProfile = returnedNumericProfile
        }
        func snapshot(library: borrowing OSDILibrary, descriptorIndex: Int, model: borrowing OSDIPreparedModel,
            preparation: OSDIPreparationOptions, semanticProfile: ContentDigest,
            options: OSDIPrecisionOptions) throws(OSDIError) -> OSDIPrecisionProgram {
            state.withLock { $0.legacySnapshots += 1 }
            return try native.snapshot(library: library, descriptorIndex: descriptorIndex, model: model,
                preparation: preparation, semanticProfile: semanticProfile, options: options)
        }
        func snapshot(library: borrowing OSDILibrary, descriptorIndex: Int, model: borrowing OSDIPreparedModel,
            preparation: OSDIPreparationOptions, semanticProfile: ContentDigest,
            options: OSDIPrecisionOptions, control: any OSDIPrecisionSnapshotControlling) throws(OSDIError) -> OSDIPrecisionProgram {
            state.withLock { $0.snapshots += 1 }
            return try native.snapshot(library: library, descriptorIndex: descriptorIndex, model: model,
                preparation: preparation, semanticProfile: semanticProfile, options: options, control: control)
        }
        func prepare(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent, source: any ArtifactAccessing,
            numericProfile: ContentDigest, options: OSDIPrecisionOptions) async throws(OSDIError) -> OSDIPrecisionSession {
            state.withLock { $0.points += 1 }
            return try await native.prepare(program: program, worker: worker, source: source,
                numericProfile: numericProfile, options: options)
        }
        func prepareConstitutiveIdentities(program: OSDIPrecisionProgram, worker: ArtifactAccessIntent,
            source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions,
            coverLimits: OSDIPrecisionDecisionCoverLimits, limits: OSDIPrecisionConstitutiveLimits,
            coordinateQuotient: OSDIPrecisionCoordinateQuotient) async throws(OSDIPrecisionConstitutiveError) -> OSDIPrecisionSession {
            state.withLock { $0.identities += 1 }
            return try await native.prepareConstitutiveIdentities(program: program, worker: worker, source: source,
                numericProfile: returnedNumericProfile ?? numericProfile, options: options, coverLimits: coverLimits, limits: limits,
                coordinateQuotient: coordinateQuotient)
        }
    }
    private struct OwnedClaims: Sendable {
        let binding: OSDIPrecisionConstitutiveBinding
        let retention: OSDIConstitutiveCaptureRetention
        private let words: [[UInt64]]
        private let lease: any Sendable
        var hasUnitPair: Bool { words == [[1], [1]] }
        init(binding: OSDIPrecisionConstitutiveBinding, retention: OSDIConstitutiveCaptureRetention, words: [[UInt64]], lease: any Sendable) {
            self.binding = binding; self.retention = retention; self.words = words; self.lease = lease
        }
    }
    private func options() throws -> OSDIPrecisionOptions {
        try OSDIPrecisionOptions(maximumProgramBytes: 1_048_576, maximumMappingBytes: 16_777_216,
            arenaBytes: 16_777_216, maximumWorkUnits: 100_000_000, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
            startupTimeoutNanoseconds: 2_000_000_000, evaluationTimeoutNanoseconds: 2_000_000_000,
            cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
    }
    private func coverLimits() throws -> OSDIPrecisionDecisionCoverLimits {
        try OSDIPrecisionDecisionCoverLimits(maximumSteps: 100_000, maximumGuardRecords: 100_000,
            maximumCopiedBytes: 10_000_000, maximumCells: 100, maximumNodes: 256, maximumLeaves: 64,
            maximumPending: 256, maximumDepth: 256, maximumIntegerBits: 1025)
    }
    private func identityLimits(nodes: UInt32 = 256) throws -> OSDIPrecisionConstitutiveLimits {
        try OSDIPrecisionConstitutiveLimits(maximumNodes: nodes, maximumAtoms: 64,
            maximumCoefficientBits: 4096, maximumWorkspaceBytes: 2_097_152)
    }
    private func external(_ key: String) throws -> String {
        try #require(ProcessInfo.processInfo.environment[key], "Required actual snapshot fixture: \(key)")
    }
    private func context() throws -> OSDIPrecisionContext { try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0) }
    private func observe<Result>(_ capture: inout OSDIConstitutiveCapture,
        lower: Double = -1, upper: Double = 1,
        _ body: (OSDIPrecisionConstitutiveEvaluationView, OSDIConstitutiveInventoryView) throws -> Result) throws -> Result {
        let lo = [lower], hi = [upper], zero = [0.0]
        return try capture.withCheckedIdentities(lowerHigh: lo.span, lowerLow: zero.span,
            upperHigh: hi.span, upperLow: zero.span, lowerContext: context(), upperContext: context(), precisionBits: 192, body)
    }
    private func withDevices(count: Int = 1, ground: Bool = false, control: OSDIConstitutiveTestControl,
        onFactory: (Factory) -> Void = { _ in },
        _ body: ([any BoundDevice], Factory, OSDIConstitutiveCaptureInputs, CircuitTopology) async throws -> Void) async throws {
        _ = try OSDIConstitutiveQualification.load()
        // Reuses the qualified public consumer's real analytic library export, not a fabricated program.
        let fixture = try OSDIAdapterFixture(library: .init(id: "constitutive-public",
            path: external("CORESPICE_OSDI_CONSTITUTIVE_MODEL"), sha256: external("CORESPICE_OSDI_CONSTITUTIVE_MODEL_SHA256"),
            descriptorIndex: 0, descriptorName: "public_precision_source"))
        do {
            let workerPath = fixture.directory.appendingPathComponent("worker")
            try FileManager.default.copyItem(atPath: external("CORESPICE_OSDI_CONSTITUTIVE_WORKER"), toPath: workerPath.path)
            let worker = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "worker"), role: .input, kind: .model, format: .raw), relativeTo: fixture.directory)
            #expect(worker.digest.hexadecimalValue == (try external("CORESPICE_OSDI_CONSTITUTIVE_WORKER_SHA256")))
            let intent = try ArtifactAccessIntent(expectedReference: worker,
                availability: .local(artifactID: worker.id, rootID: fixture.provider.root.rootID, relativePath: ArtifactRelativePath(segments: ["worker"])),
                operation: .read, budget: ArtifactAccessBudget(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            let factory = Factory(directory: fixture.directory), policy = try options()
            onFactory(factory)
            let snapshot = OSDIConstitutiveSnapshotInputs(preparer: factory,
                semanticProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: external("CORESPICE_OSDI_CONSTITUTIVE_MODEL_SEMANTIC_SHA256")),
                options: policy, control: control)
            let inputs = try OSDIConstitutiveCaptureInputs(preparer: factory, evaluator: OSDINativePrecisionEvaluator(),
                worker: intent, source: fixture.provider.root,
                numericProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: external("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")),
                options: policy, coverLimits: coverLimits(), limits: identityLimits())
            let node = ground ? Node.ground : Node(id: 1)
            let instances = try (0..<count).map { try fixture.instance("N\($0)", nodes: [node]) }
            let preparer: any OSDIConstitutiveCircuitPreparing = OSDICircuitPreparer()
            var prepared = try await preparer.prepare(ir: CircuitIR(nodes: [node], branches: [], instances: instances),
                operatingConditions: .nominal, provider: fixture.provider,
                loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
                evaluationLimits: OSDIEvaluationLimits(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 64,
                    maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: count,
                maximumAdapterBytes: 1_073_741_824, transientPrecision: nil, constitutiveSnapshot: snapshot)
            do {
                let topology = CircuitTopology(ir: prepared.circuit)
                var binding = fixture.context(topology), devices: [any BoundDevice] = []
                for i in 0..<count {
                    guard let pending = try prepared.takeDevice(at: i) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                    let bound = try pending.bind(context: &binding)
                    let actual = try #require(bound as? BoundOSDIDevice)
                    let retained = try #require(actual.constitutiveSnapshot)
                    #expect(retained.program.programDigest.hexadecimalValue == (try external("CORESPICE_OSDI_CONSTITUTIVE_PROGRAM_SHA256")))
                    #expect(retained.program.programByteCount > 0 && retained.program.setupByteCount > 0)
                    #expect(actual.transientPrecisionReceipt == nil)
                    devices.append(bound)
                }
                #expect(factory.counts.snapshots == count && factory.counts.legacySnapshots == 0 && factory.counts.points == 0)
                try await body(devices, factory, inputs, topology)
            } catch { try prepared.close(); throw error }
            try prepared.close()
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }

    @Test func actualGroundClaimsReuseOneSessionAndCopiesRetainAdmissionAfterClose() async throws {
        let control = OSDIConstitutiveTestControl()
        var retained: OwnedClaims?
        try await withDevices(ground: true, control: control) { devices, factory, inputs, _ in
            let bound = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            var capture = try await bound.prepareConstitutiveCapture(inputs: inputs)
            do {
                let first = try observe(&capture) { view, inventory -> OwnedClaims in
                    let lower = view.cover.lowerHigh[0], upper = view.cover.upperHigh[0], leaves = view.cover.leafCount
                    let claims = view.claimCount, name = inventory.instanceName, dimension = inventory.matrixDimension
                    let activeCount = inventory.activeGlobal.count, rawCount = inventory.rawGlobal.count
                    let activeRow = inventory.activeGlobal[0], rawRow = inventory.rawGlobal[0]
                    let binding = view.binding
                    #expect(binding.source.programDigest.hexadecimalValue == (try external("CORESPICE_OSDI_CONSTITUTIVE_PROGRAM_SHA256")))
                    #expect(lower == -1 && upper == 1 && leaves == 1)
                    #expect(claims == 2 && name == "N0" && dimension == 0)
                    #expect(activeCount == 1 && rawCount == 1 && activeRow == nil && rawRow == nil)
                    #expect(binding.coordinateQuotient.representatives == [UInt32.max])
                    let lease = try control.reserveStorage(byteCount: 128)
                    try control.checkpoint(workUnits: 4)
                    var words: [[UInt64]] = []
                    for i in 0..<view.claimCount {
                        let copied: Swift.Result<Void, any Error> = view.withClaim(at: i) { claim in
                            let rows = claim.rawRowCount, source = claim.binding
                            #expect(rows == 1 && source == binding)
                            return claim.withCoefficient(at: 0) { value in
                                do {
                                    let count = value.numeratorWords.count, negative = value.negative, power = value.denominatorPower
                                    #expect(!negative && power == 0 && count == 1)
                                    try control.checkpoint(workUnits: count * 2)
                                    var copy = [UInt64](repeating: 0, count: count)
                                    for j in 0..<count { copy[j] = value.numeratorWords[j] }
                                    words.append(copy)
                                    return .success(())
                                } catch { return .failure(error) }
                            }
                        }
                        try copied.get()
                    }
                    let retention = inventory.retention
                    if let retention {
                        #expect(retention.workerReference == inputs.worker.expectedReference && retention.numericProfile == inputs.numericProfile)
                        #expect(retention.options == inputs.options && retention.identityLimits == inputs.limits)
                    }
                    return OwnedClaims(binding: view.binding, retention: try #require(retention), words: words, lease: lease)
                }
                let work = control.counters.work
                try observe(&capture, lower: -2, upper: 2) { view, inventory in
                    let binding = view.binding, sequence = view.cover.requestSequence
                    let lower = view.cover.lowerHigh[0], upper = view.cover.upperHigh[0], quotient = inventory.coordinateQuotient
                    #expect(binding == first.binding && sequence == 2)
                    #expect(lower == -2 && upper == 2)
                    #expect(quotient == binding.coordinateQuotient)
                }
                #expect(control.counters.work - work < Int(inputs.options.maximumWorkUnits))
                retained = first
            } catch { try capture.close(); throw error }
            try capture.close(); try capture.close()
            #expect(factory.counts.identities == 1 && factory.counts.points == 0)
            do { try observe(&capture) { _, _ in Issue.record("Closed capture published") }; Issue.record("Closed capture succeeded") }
            catch OSDIConstitutiveCaptureFailure.closed {}
        }
        let copiedValuesAreExact = retained?.hasUnitPair
        #expect(copiedValuesAreExact == true)
        #expect(control.counters.live > 128)
        retained = nil
        #expect(control.counters.live == 0)
    }

    @Test func sharedInvocationAllowanceRefusesSecondInstanceBeforeHelperStartup() async throws {
        let policy = try options()
        // One session allowance plus bounded synthetic construction work; two
        // full session allowances cannot fit in this immutable request ceiling.
        let control = OSDIConstitutiveTestControl(work: Int(policy.maximumWorkUnits) + 1_000_000)
        try await withDevices(count: 2, control: control) { devices, factory, inputs, _ in
            let first = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            let second = try #require(devices[1] as? any OSDIConstitutiveCapturePreparing)
            var capture = try await first.prepareConstitutiveCapture(inputs: inputs)
            try capture.close()
            let work = control.counters.work
            do { var rejected = try await second.prepareConstitutiveCapture(inputs: inputs); try rejected.close(); Issue.record("Second allowance admitted") }
            catch OSDIConstitutiveTestControl.Refusal.work {}
            #expect(factory.counts.identities == 1 && control.counters.work >= work)
        }
        #expect(control.counters.live == 0)
    }

    @Test func cancellationAndCallbackFailureCloseOnlyTheIdentityHelper() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(control: control) { devices, factory, inputs, topology in
            let bound = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            var capture = try await bound.prepareConstitutiveCapture(inputs: inputs)
            do {
                try observe(&capture) { _, _ in throw OSDIConstitutiveTestControl.Refusal.storage }
                Issue.record("Failed copy published a successful result")
            } catch OSDIConstitutiveCaptureFailure.control(let underlying) {
                #expect(underlying as? OSDIConstitutiveTestControl.Refusal == .storage)
            }
            try capture.close()
            var f = 0.0
            let physical = try #require(devices[0] as? any OSDIPhysicalResidualContributing)
            try physical.accumulatePhysicalResidual(state: SolutionState(variables: [0.75], variableMap: topology.variableMap)) { _, value in f += value }
            #expect(f == 0.75)
            control.cancel()
            do { var rejected = try await bound.prepareConstitutiveCapture(inputs: inputs); try rejected.close(); Issue.record("Cancelled capture started") }
            catch OSDIConstitutiveTestControl.Refusal.cancelled {}
            #expect(factory.counts.identities == 1)
        }
        #expect(control.counters.live == 0)
    }

    @Test func emptyActualGroundIntersectionNeverPublishes() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(ground: true, control: control) { devices, _, inputs, _ in
            let bound = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            var capture = try await bound.prepareConstitutiveCapture(inputs: inputs)
            var called = false
            do { try observe(&capture, lower: 1, upper: 2) { _, _ in called = true }; Issue.record("Empty D intersect E succeeded") }
            catch OSDIConstitutiveCaptureFailure.proof(.emptyCoordinateCondition(_)) {}
            try capture.close()
            #expect(!called)
        }
        #expect(control.counters.live == 0)
    }

    @Test func wrongSnapshotPolicyAndMissingAuthorityRefuseBeforeAnyHelper() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(control: control) { devices, factory, inputs, _ in
            let actual = try #require(devices[0] as? BoundOSDIDevice)
            let missing = BoundOSDIDevice(instance: actual.instance, owner: actual.owner, mapping: actual.mapping,
                residualNoiseSources: actual.residualNoiseSources, hasReactiveResidual: actual.hasReactiveResidual,
                transientPrecisionReceipt: nil)
            do { var rejected = try await missing.prepareConstitutiveCapture(inputs: inputs); try rejected.close(); Issue.record("Missing authority admitted") }
            catch OSDIConstitutiveCaptureFailure.missingSnapshot {}
            let policy = try OSDIPrecisionOptions(maximumProgramBytes: inputs.options.maximumProgramBytes,
                maximumMappingBytes: inputs.options.maximumMappingBytes, arenaBytes: inputs.options.arenaBytes,
                maximumWorkUnits: 1, minimumPrecisionBits: 128, maximumPrecisionBits: 256,
                startupTimeoutNanoseconds: inputs.options.startupTimeoutNanoseconds,
                evaluationTimeoutNanoseconds: inputs.options.evaluationTimeoutNanoseconds,
                cleanupTimeoutNanoseconds: inputs.options.cleanupTimeoutNanoseconds, pollNanoseconds: inputs.options.pollNanoseconds)
            let mismatch = OSDIConstitutiveCaptureInputs(preparer: inputs.preparer, evaluator: inputs.evaluator,
                worker: inputs.worker, source: inputs.source, numericProfile: inputs.numericProfile,
                options: policy, coverLimits: inputs.coverLimits, limits: inputs.limits)
            do { var rejected = try await actual.prepareConstitutiveCapture(inputs: mismatch); try rejected.close(); Issue.record("Changed policy admitted") }
            catch OSDIConstitutiveCaptureFailure.invalidBinding {}
            #expect(factory.counts.identities == 0)
        }
        #expect(control.counters.live == 0)
    }

    @Test func returnedSessionProfileMismatchKeepsScheduledAllowanceAndReleasesUnpublishedStorage() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(control: control) { devices, factory, inputs, _ in
            let actual = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            // Inputs keep the externally qualified profile. Only the injected
            // factory's actual native session reports the forged profile.
            let mismatchingFactory = Factory(directory: factory.native.stagingParentDirectory,
                returnedNumericProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "0", count: 64)))
            let mismatch = OSDIConstitutiveCaptureInputs(preparer: mismatchingFactory, evaluator: inputs.evaluator,
                worker: inputs.worker, source: inputs.source, numericProfile: inputs.numericProfile,
                options: inputs.options, coverLimits: inputs.coverLimits, limits: inputs.limits)
            let before = control.counters
            do { var rejected = try await actual.prepareConstitutiveCapture(inputs: mismatch); try rejected.close(); Issue.record("Forged returned profile admitted") }
            catch OSDIConstitutiveCaptureFailure.invalidBinding {}
            #expect(mismatchingFactory.counts.identities == 1 && factory.counts.identities == 0)
            #expect(control.counters.work >= before.work + Int(inputs.options.maximumWorkUnits))
            #expect(control.counters.live == before.live)
        }
        #expect(control.counters.live == 0)
    }

    @Test func actualCleanupFailureRetainsHelperLeaseUntilExplicitRetry() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(control: control) { devices, factory, inputs, _ in
            let actual = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            let directory = factory.native.stagingParentDirectory
            let before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            var capture = try await actual.prepareConstitutiveCapture(inputs: inputs)
            let after = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            let added = after.subtracting(before)
            #expect(added.count == 1)
            let original = try #require(added.first)
            let held = directory.appendingPathComponent("held-helper")
            try FileManager.default.moveItem(at: original, to: held)
            let live = control.counters.live
            var pending: OSDIConstitutiveCaptureCleanup?
            do { try capture.close(); Issue.record("Missing staging directory cleanup succeeded") }
            catch OSDIConstitutiveCaptureFailure.cleanupPending(_, _, let owner) { pending = owner }
            #expect(pending != nil && control.counters.live == live)
            try FileManager.default.moveItem(at: held, to: original)
            try pending?.close(); try pending?.close()
            #expect(control.counters.live == live - (try OSDIConstitutiveCapacity.helper(options: inputs.options)))
            pending = nil
            try capture.close()
        }
        #expect(control.counters.live == 0)
    }


    @Test func controlledSnapshotRefusesStorageBeforeReturningAnyProgram() async throws {
        let control = OSDIConstitutiveTestControl(storage: 1)
        var observed: Factory?
        do {
            try await withDevices(control: control, onFactory: { observed = $0 }) { _, _, _, _ in
                Issue.record("Cold snapshot exceeded storage admission")
            }
            Issue.record("Cold snapshot refusal succeeded")
        } catch OSDIAdapterFailure.runtime(.host(let operation, let underlying)) {
            #expect(operation == "controlled precision snapshot")
            #expect(underlying as? OSDIConstitutiveTestControl.Refusal == .storage)
        }
        let counts = try #require(observed).counts
        #expect(counts.snapshots == 1 && counts.legacySnapshots == 0 && counts.points == 0 && counts.identities == 0)
        #expect(control.counters.live == 0)
    }

    @Test func controlledSnapshotWorkFailurePreservesOriginalCallerError() async throws {
        let control = OSDIConstitutiveTestControl(work: 1)
        do {
            try await withDevices(control: control) { _, _, _, _ in Issue.record("Snapshot work quota bypassed") }
            Issue.record("Snapshot work refusal succeeded")
        } catch OSDIAdapterFailure.runtime(.host(let operation, let underlying)) {
            #expect(operation == "controlled precision snapshot")
            #expect(underlying as? OSDIConstitutiveTestControl.Refusal == .work)
        }
        #expect(control.counters.live == 0)
    }

    @Test func controlledSnapshotMidConstructionCancellationRefundsStorage() async throws {
        let control = OSDIConstitutiveTestControl(cancelAfterWork: 100)
        var observed: Factory?
        do {
            try await withDevices(control: control, onFactory: { observed = $0 }) { _, _, _, _ in
                Issue.record("Cancelled snapshot published devices")
            }
            Issue.record("Cancelled snapshot succeeded")
        } catch OSDIAdapterFailure.runtime(.host(let operation, let underlying)) {
            #expect(operation == "controlled precision snapshot")
            #expect(underlying as? OSDIConstitutiveTestControl.Refusal == .cancelled)
        }
        let counts = try #require(observed).counts
        #expect(counts.snapshots == 1 && counts.legacySnapshots == 0 && counts.points == 0 && counts.identities == 0)
        #expect(control.counters.work > 0 && control.counters.live == 0)
    }

    @Test func snapshotBridgeRejectsUnrepresentableCountsWithoutCallingOwner() throws {
        let control = OSDIConstitutiveTestControl()
        let bridge = OSDIConstitutiveSnapshotControl(control: control)
        do { try bridge.checkpoint(workUnits: UInt64.max); Issue.record("Unrepresentable work admitted") }
        catch OSDIConstitutiveCaptureFailure.capacityExceeded {}
        do { _ = try bridge.reserveStorage(byteCount: UInt64.max); Issue.record("Unrepresentable storage admitted") }
        catch OSDIConstitutiveCaptureFailure.capacityExceeded {}
        #expect(control.counters.work == 0 && control.counters.live == 0)
    }

    @Test func lastCaptureOwnerClosesHelperBeforeRefundEvenWithoutExplicitClose() async throws {
        let control = OSDIConstitutiveTestControl()
        try await withDevices(control: control) { devices, factory, inputs, _ in
            let actual = try #require(devices[0] as? any OSDIConstitutiveCapturePreparing)
            let before = control.counters.live
            do {
                var capture = try await actual.prepareConstitutiveCapture(inputs: inputs)
                #expect(control.counters.live > before)
                try observe(&capture) { _, _ in }
                // Scope exit intentionally exercises the capture's private storage owner.
            }
            #expect(control.counters.live == before && factory.counts.identities == 1)
        }
        #expect(control.counters.live == 0)
    }

    @Test func externalQualifierRejectsChangedNumericProfileDigest() throws {
        #expect(throws: OSDIConstitutiveQualification.Refusal.invalidBinding) {
            _ = try OSDIConstitutiveQualification.load(expectedNumericProfile: String(repeating: "0", count: 64))
        }
    }

    @Test func externalQualifierRejectsChangedWorkerArtifactBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forged-constitutive-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Forged worker fixture cleanup failed: \(error)") }
        }
        let forged = directory.appendingPathComponent("worker")
        try Data([0]).write(to: forged)
        #expect(throws: OSDIConstitutiveQualification.Refusal.invalidBinding) {
            _ = try OSDIConstitutiveQualification.load(runtimeWorkerPath: forged.path)
        }
    }

}
