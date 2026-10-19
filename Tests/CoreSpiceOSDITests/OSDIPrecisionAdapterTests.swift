import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpiceIR
import CoreSpiceDevices
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDIPrecisionAdapterTests {
    @Test func subULPChargeHistoryAndReceiptSurviveRejectedTrialsAndRestart() async throws {
        try await withDevice { device, topology, receipt in
            let session = try #require(device as? any TransientSessionDevice)
            let enclosed = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
            let exposed = try #require(device as? any OSDITransientPrecisionProviding)
            #expect(exposed.transientPrecisionReceipt?.program.programDigest == receipt.program.programDigest)
            #expect(exposed.transientPrecisionReceipt?.program.setupDigest == receipt.program.setupDigest)
            #expect(!receipt.program.programBytes.isEmpty && !receipt.program.setupBytes.isEmpty)
            #expect(receipt.precisionBits == 192)
            func state(_ low: Double) -> SolutionState {
                SolutionState(variables: [1], variableMap: topology.variableMap, variableLowComponents: [low])
            }
            func value(_ low: Double, _ integration: IntegrationState) throws -> CompensatedEnclosure {
                var result = try CompensatedEnclosure(center: .zero)
                try enclosed.accumulateTransientPhysicalResidualEnclosure(state: state(low), integration: integration) { row, center, radius in
                    #expect(row == 0)
                    do { result = try CompensatedEnclosure(center: center, radius: radius) }
                    catch { Issue.record("Invalid returned enclosure") }
                }
                return result
            }
            try session.beginTransientSession(initialState: state(0), initialization: .initialConditions)
            defer { session.endTransientSession() }
            let be = IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 1)
            let earlyTR = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 1)
            do { _ = try value(1e-20, earlyTR); Issue.record("TR admitted before accepted derivative") }
            catch { guard case OSDIAdapterFailure.invalidIntegration = error else { throw error } }
            _ = try value(9e-20, be)
            let first = try value(1e-20, be)
            #expect(first.center.high == 2)
            #expect(abs(first.center.low - (2e-20 + 1e-29)) < 1e-35)
            #expect(first.radius < 1e-35)
            let repeated = try value(1e-20, be)
            #expect(first == repeated)
            var matrix = 0.0
            var stamp = MatrixStamper(variableMap: topology.variableMap, stampMatrix: { _, _, _ in Issue.record("Unexpected row lookup") },
                stampRHS: { _, _ in }, stampValue: { _, value in matrix += value })
            try device.stampTransient(into: &stamp, state: state(1e-20), integration: be)
            #expect(abs(matrix - (2 + 1e-9)) < 1e-15)
            try session.commitTransientStep(state: state(1e-20), integration: be)
            let tr = IntegrationState(method: .trapezoidal, timeStep: 2, currentTime: 3, previousTimeStep: 1)
            _ = try value(8e-20, tr)
            let second = try value(3e-20, tr)
            #expect(abs(second.center.low - (6e-20 + 1e-29)) < 1e-35)
            #expect(second.radius < 1e-35)
            try session.commitTransientStep(state: state(3e-20), integration: tr)
            session.endTransientSession()
            try session.beginTransientSession(initialState: state(0), initialization: .operatingPoint)
            #expect(try value(1e-20, be) == first)
        }
    }

    @Test func sameTrialPairedGatesShareOneWorkerEvaluationWithoutLosingSourceRadiiOrLowCoordinates() async throws {
        try await withDevice(contextModel: true) { bound, topology, _ in
            let device = try #require(bound as? BoundOSDIDevice)
            let initial = SolutionState(variables: [1], variableMap: topology.variableMap, variableLowComponents: [0])
            func candidate(_ low: Double) -> SolutionState {
                .init(variables: [1], previousVariables: [1], variableMap: topology.variableMap,
                    variableLowComponents: [low], previousVariableLowComponents: [0])
            }
            let state = candidate(1e-20)
            let step = IntegrationState(method: .backwardEuler, timeStep: 0.125, currentTime: 0.125)
            try device.beginTransientSession(initialState: initial, initialization: .initialConditions)
            defer { device.endTransientSession() }
            func count() throws -> UInt64 { try #require(device.owner.transientSourceFactEvaluationCount) }
            func companion() throws {
                try device.accumulateTransientPhysicalResidualEnclosure(state: state, integration: step) { _, _, _ in }
            }
            func terms(_ value: SolutionState, _ integration: IntegrationState) throws -> [CompensatedEnclosure] {
                var result = [try CompensatedEnclosure(center: .zero), try CompensatedEnclosure(center: .zero)]
                var failure: (any Error)?
                try device.accumulateTransientPhysicalEquationEnclosure(state: value, integration: integration) { _, term, center, radius in
                    do {
                        let enclosed = try CompensatedEnclosure(center: center, radius: radius)
                        switch term {
                        case .staticResidual: result[0] = enclosed
                        case .chargeDifference: result[1] = enclosed
                        default: Issue.record("Unexpected nonconservative source")
                        }
                    } catch { failure = error }
                }
                if let failure { throw failure }
                return result
            }
            let fresh = try terms(state, step)
            let start = try count()
            try companion()
            try device.accumulateTransientStaticResidualEnclosure(state: initial, time: 0) { _, _, _ in }
            #expect(try terms(state, step) == fresh, "Both source centers and radii must match the fresh precise path exactly")
            #expect(try count() - start == 1, "Both gates must use one real precision worker request")
            #expect(fresh[0].center.low != 0 && fresh[0].radius < 1e-28)
            var before = try count()
            try companion()
            let changed = try terms(candidate(2e-20), step)
            #expect(try count() - before == 2)
            #expect(abs(changed[0].center.low - 4e-20) < 1e-35)
            before = try count()
            try companion()
            _ = try terms(state, .init(method: .backwardEuler, timeStep: 0.125, currentTime: 0.125,
                previousTimeStep: 0.125, previousTimeStepLowComponent: 0))
            #expect(try count() - before == 2)
            try companion()
            before = try count()
            #expect(throws: OSDIAdapterFailure.self) {
                try device.accumulateTransientPhysicalResidualEnclosure(
                    state: .init(variables: [1], variableMap: topology.variableMap, variableLowComponents: []),
                    integration: step) { _, _, _ in }
            }
            #expect(try terms(state, step) == fresh)
            #expect(try count() == before + 1, "Malformed input must invalidate the old successful record")
            try companion()
            before = try count()
            device.endTransientSession()
            try device.beginTransientSession(initialState: initial, initialization: .operatingPoint)
            #expect(try terms(state, step) == fresh)
            #expect(try count() == before + 1, "New generation and original IC reference context require fresh facts")
        }
    }

    @Test func decompositionKeepsActualPairedStaticAndInitializationChargeContext() async throws {
        try await withDevice(contextModel: true) { device, topology, _ in
            let session = try #require(device as? any TransientSessionDevice)
            let equations = try #require(device as? any TransientPhysicalEquationEnclosureDecomposing)
            let initial = SolutionState(variables: [1], variableMap: topology.variableMap, variableLowComponents: [0])
            try session.beginTransientSession(initialState: initial, initialization: .initialConditions)
            defer { session.endTransientSession() }
            var initialF = try CompensatedEnclosure(center: .zero)
            var failure: (any Error)?
            try equations.accumulateTransientStaticResidualEnclosure(state: initial, time: 0) { _, center, radius in
                do { initialF = try CompensatedEnclosure(center: center, radius: radius) } catch { failure = error }
            }
            if let failure { throw failure }
            #expect(initialF.center == (try CompensatedValue(high: 1)))
            let trial = SolutionState(variables: [1], previousVariables: [1], variableMap: topology.variableMap,
                variableLowComponents: [1e-20], previousVariableLowComponents: [0])
            let step = IntegrationState(method: .backwardEuler, timeStep: 0.125, currentTime: 0.125)
            var f = try CompensatedEnclosure(center: .zero), increment = try CompensatedEnclosure(center: .zero)
            try equations.accumulateTransientPhysicalEquationEnclosure(state: trial, integration: step) { _, term, center, radius in
                do {
                    let value = try CompensatedEnclosure(center: center, radius: radius)
                    switch term { case .staticResidual: f = value; case .chargeDifference: increment = value; default: Issue.record("Unexpected differential law") }
                } catch { failure = error }
            }
            if let failure { throw failure }
            #expect(f.center.high == 1 && abs(f.center.low - 2e-20) < 1e-35)
            // The actual accepted IC endpoint contributes its 2e-12 charge offset.
            #expect(abs(increment.center.high + 1.5e-11) < 1e-26)
            #expect(f.radius < 1e-28 && increment.radius < 1e-28)
            var cached = try CompensatedEnclosure(center: .zero)
            try equations.accumulateTransientStaticResidualEnclosure(state: initial, time: 0) { _, center, radius in
                do { cached = try CompensatedEnclosure(center: center, radius: radius) } catch { failure = error }
            }
            if let failure { throw failure }
            #expect(cached == initialF)
            #expect(throws: (any Error).self) {
                try equations.accumulateTransientStaticResidualEnclosure(state: trial, time: 0) { _, _, _ in }
            }
            try session.commitTransientStep(state: trial, integration: step)
            #expect(throws: (any Error).self) {
                try equations.accumulateTransientStaticResidualEnclosure(state: initial, time: 0) { _, _, _ in }
            }
        }
    }

    @Test func endpointContextsExactStepAndSameCallBoundRemainAuthoritative() async throws {
        try await withDevice(contextModel: true) { device, topology, _ in
            let session = try #require(device as? any TransientSessionDevice)
            let enclosed = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
            let constrained = try #require(device as? any TransientTrialTimeStepConstraintDevice)
            let state = SolutionState(variables: [1], variableMap: topology.variableMap)
            func value(_ integration: IntegrationState) throws -> Double {
                var value = 0.0
                try enclosed.accumulateTransientPhysicalResidualEnclosure(state: state, integration: integration) { _, center, radius in
                    value += center.high + center.low; #expect(radius < 1e-28)
                }
                return value
            }
            try session.beginTransientSession(initialState: state, initialization: .initialConditions)
            defer { session.endTransientSession() }
            let first = IntegrationState(method: .backwardEuler, timeStep: 0.125, currentTime: 0.125)
            #expect(abs(try value(first) - (1 - 15e-12)) < 1e-16)
            #expect(try constrained.maximumTransientTimeStep(state: state, integration: first) == 0.25)
            let oversized = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
            do { try session.commitTransientStep(state: state, integration: oversized); Issue.record("Bound violation committed") }
            catch { guard case OSDIAdapterFailure.transientTimeStepExceedsBound = error else { throw error } }
            #expect(abs(try value(first) - (1 - 15e-12)) < 1e-16)
            try session.commitTransientStep(state: state, integration: first)
            let tr = IntegrationState(method: .trapezoidal, timeStep: 0.125, currentTime: 0.25, previousTimeStep: 0.125)
            #expect(abs(try value(tr) - (1 + 17e-12)) < 1e-16)
            let wrongStep = IntegrationState(method: .backwardEuler, timeStep: 0.124, currentTime: 0.25)
            do { _ = try value(wrongStep); Issue.record("Different endpoint denominator admitted") }
            catch { guard case OSDIAdapterFailure.invalidIntegration = error else { throw error } }
            let malformed = SolutionState(variables: [1], variableMap: topology.variableMap, variableLowComponents: [])
            do {
                try enclosed.accumulateTransientPhysicalResidualEnclosure(state: malformed, integration: tr) { _, _, _ in Issue.record("Malformed pair published") }
                Issue.record("Malformed low vector admitted")
            } catch { guard case OSDIAdapterFailure.invalidMatrixMapping = error else { throw error } }
            #expect(abs(try value(tr) - (1 + 17e-12)) < 1e-16)
        }
    }

    @Test func coldReceiptBudgetRefusesBeforePrecisionSnapshot() async throws {
        let recorder = RecordingPreparer()
        do {
            try await withDevice(preparer: recorder, maximumAdapterBytes: 1_048_576) { _, _, _ in
                Issue.record("Insufficient cold snapshot budget admitted")
            }
            Issue.record("Capacity refusal missing")
        } catch { guard case OSDIAdapterFailure.capacityExceeded = error else { throw error } }
        #expect(recorder.calls == 0)
    }

    @Test func workerWorkExhaustionNeverFallsBackToOrdinaryModel() async throws {
        try await withDevice(maximumWorkUnits: 1) { device, topology, _ in
            let session = try #require(device as? any TransientSessionDevice)
            let state = SolutionState(variables: [1], variableMap: topology.variableMap)
            do { try session.beginTransientSession(initialState: state); Issue.record("Work exhaustion accepted") }
            catch { guard case OSDIAdapterFailure.runtime = error else { throw error } }
            // Ordinary ownership remains independent after the failed precision request.
            var matrix = 0.0
            var stamp = MatrixStamper(variableMap: topology.variableMap, stampMatrix: { _, _, _ in }, stampRHS: { _, _ in },
                stampValue: { _, value in matrix += value })
            try device.stampDC(into: &stamp, state: state)
            #expect(matrix == 2)
            do { try session.beginTransientSession(initialState: state); Issue.record("Dead helper silently replaced") }
            catch { guard case OSDIAdapterFailure.runtime = error else { throw error } }
        }
    }

    private func withDevice(contextModel: Bool = false, preparer: any OSDIPrecisionSessionPreparing = OSDINativePrecisionSessionPreparer(),
        maximumAdapterBytes: UInt64 = 67_108_864, maximumWorkUnits: UInt64 = 100_000_000,
        _ body: (any BoundDevice, CircuitTopology, OSDITransientPrecisionReceipt) throws -> Void) async throws {
        let prefix = contextModel ? "CORESPICE_OSDI_PRECISION_CONTEXT_MODEL" : "CORESPICE_OSDI_PRECISION_MODEL"
        let fixture = try OSDIAdapterFixture(library: .init(id: "precision", path: external(prefix), sha256: external(prefix + "_SHA256"),
            descriptorIndex: 0, descriptorName: contextModel ? "precision_context" : "precision_compound"))
        do {
            let workerPath = fixture.directory.appendingPathComponent("worker")
            try FileManager.default.copyItem(atPath: external("CORESPICE_OSDI_PRECISION_WORKER"), toPath: workerPath.path)
            let worker = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "worker"), role: .input, kind: .model, format: .raw), relativeTo: fixture.directory)
            let intent = try ArtifactAccessIntent(expectedReference: worker,
                availability: .local(artifactID: worker.id, rootID: fixture.provider.root.rootID,
                    relativePath: ArtifactRelativePath(segments: ["worker"])), operation: .read,
                budget: ArtifactAccessBudget(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            let options = try OSDIPrecisionOptions(maximumProgramBytes: 16_777_216, maximumMappingBytes: 16_777_216,
                arenaBytes: 16_777_216, maximumWorkUnits: maximumWorkUnits, minimumPrecisionBits: 53, maximumPrecisionBits: 256,
                startupTimeoutNanoseconds: 2_000_000_000, evaluationTimeoutNanoseconds: 2_000_000_000,
                cleanupTimeoutNanoseconds: 1_000_000_000, pollNanoseconds: 1_000_000)
            let inputs = OSDITransientPrecisionInputs(preparer: preparer, worker: intent, source: fixture.provider.root,
                semanticProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: external("CORESPICE_OSDI_PRECISION_SEMANTIC_SHA256")),
                numericProfile: try ContentDigest(algorithm: .sha256, hexadecimalValue: external("CORESPICE_OSDI_PRECISION_NUMERIC_SHA256")),
                options: options, precisionBits: 192)
            let instance = try fixture.instance("X1", nodes: [Node(id: 1)])
            var prepared = try await OSDICircuitPreparer().prepare(ir: CircuitIR(nodes: [Node(id: 1)], branches: [], instances: [instance]),
                operatingConditions: .nominal, provider: fixture.provider,
                loadLimits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 16_777_216),
                evaluationLimits: OSDIEvaluationLimits(maximumWorkspaceBytes: 16_777_216, maximumDiagnosticCount: 64,
                    maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 1,
                maximumAdapterBytes: maximumAdapterBytes, transientPrecision: inputs)
            let lifetime = prepared.lifetime
            do {
                let topology = CircuitTopology(ir: prepared.circuit)
                var context = fixture.context(topology)
                guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                guard let receipt = owner.transientPrecisionReceipt else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                let device = try owner.bind(context: &context)
                try body(device, topology, receipt)
            } catch { try lifetime.close(); throw error }
            try lifetime.close()
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }
    private func external(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name] else { throw MissingInput(name: name) }
        return value
    }
    private struct MissingInput: Error { let name: String }
}
