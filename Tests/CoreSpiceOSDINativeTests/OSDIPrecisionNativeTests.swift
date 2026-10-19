import Foundation
import CircuiteFoundation
@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import OSDIContracts
import OSDIRuntime
import Testing

@Suite("Actual native OSDI precision", .serialized, .timeLimit(.minutes(2)))
struct OSDIPrecisionNativeTests {
    @Test func compoundOriginalEquationRetainsSubULPStateColdEvidenceAndFreshRerun() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let input = try await fixture.input()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
        let runtime = try fixture.runtime(provider: tracked)
        let native = SPICENativeSimulation()
        let identity: ContentDigest
        let cold: OSDITransientPrecisionReceipt
        let high: [Double], low: [Double]
        let retainedInput: PreparedSPICESimulation, retainedRuntime: SPICEOSDIRuntimeInputs
        do {
            let prepared = try await native.prepare(input, limits: fixture.limits, osdi: runtime)
            let inspection = prepared.record
            cold = try #require(inspection.osdiPreparationRecords.first?.transientPrecision)
            #expect(fixture.preparer.snapshotCount == 1 && fixture.preparer.launchCount == 1)
            let output = try await native.execute(prepared, cancellation: .init())
            identity = output.configurationIdentity
            retainedInput = output.prepared.input
            retainedRuntime = try #require(output.prepared.osdiRuntimeInputs)
            let result = try #require(output.transientResult)
            high = result.solutionTrace.rowMajorValues
            low = try #require(result.solutionLowTrace).rowMajorValues
            try checkEvidence(output, fixture: fixture, modelID: "compound")
            try checkOriginalCompound(result)
            #expect(output.prepared.algorithmIdentity == "CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3")
        }
        try tracked.expectClosed()
        #expect(try fixture.digest(cold.program.programBytes) == cold.program.programDigest)
        #expect(try fixture.digest(cold.program.setupBytes) == cold.program.setupDigest)
        let fresh = try await native.prepare(retainedInput, limits: fixture.limits, osdi: retainedRuntime)
        let freshIdentity = fresh.configurationIdentity
        #expect(freshIdentity == identity)
        let rerun = try await native.execute(fresh, cancellation: .init())
        let result = try #require(rerun.transientResult)
        #expect(result.solutionTrace.rowMajorValues == high)
        #expect(result.solutionLowTrace?.rowMajorValues == low)
        #expect(fixture.preparer.snapshotCount == 2 && fixture.preparer.launchCount == 2)
        #expect(tracked.count == 2)
        try tracked.expectClosed()
        // The full immutable cold snapshot remains usable after both model owners close.
        var session = try await OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.analysis.base.directory)
            .prepare(program: cold.program, worker: fixture.worker, source: fixture.source,
                numericProfile: cold.numericProfile, options: cold.options)
        defer { do { try session.close() } catch { Issue.record("Cold replay cleanup failed") } }
        let candidate = [1.0], delta = [0x1p-56], zero = [0.0]
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 1, timeLow: 0)
        try OSDINativePrecisionEvaluator().evaluate(session: &session,
            candidateHigh: candidate.span, candidateLow: delta.span, referenceHigh: candidate.span, referenceLow: zero.span,
            candidateContext: context, referenceContext: context, precisionBits: cold.precisionBits) { view in
            #expect(view.fHigh[0] == 2 && view.fLow[0] > 0)
            #expect(view.deltaQHigh[0] != 0 && view.deltaQRadius[0] < 1e-40)
        }
    }

    @Test func explicitInitializationAndTimeContextsSurviveActualNativeCommitHistory() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let input = try await fixture.input(modelID: "context")
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: fixture.runtime())
        let output = try await native.execute(prepared, cancellation: .init())
        try checkEvidence(output, fixture: fixture, modelID: "context")
        let result = try #require(output.transientResult)
        let zero = try CompensatedEnclosure(center: .zero)
        let one = try CompensatedEnclosure(center: CompensatedValue(high: 1))
        let two = try CompensatedEnclosure(center: CompensatedValue(high: 2))
        // Front-end decoded primitive binary64 literals are exact program leaves.
        // Preserve those coefficients and the saved voltage pairs before taking
        // charge differences and dividing by the exact accepted interval.
        let capacitance = try CompensatedEnclosure(center: CompensatedValue(high: 1e-9))
        let timeCoefficient = try CompensatedEnclosure(center: CompensatedValue(high: 1e-12))
        let initialCharge = try CompensatedEnclosure(center: CompensatedValue(high: 2e-12))
        var previous = one, previousTime = zero, previousIq = zero
        for (index, step) in result.acceptedSteps.enumerated() {
            let value = try result.checkedCompensatedValue(variableIndex: 0, timeIndex: index + 1)
            let voltage = try CompensatedEnclosure(center: value)
            let time = try CompensatedEnclosure(center: CompensatedValue(high: step.time))
            let interval = try CompensatedEnclosure(center: CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent))
            let previousQContext = try index == 0 ? initialCharge : timeCoefficient.multiplied(by: previousTime)
            let deltaQ = try capacitance.multiplied(by: voltage.subtracting(previous))
                .adding(timeCoefficient.multiplied(by: time)).subtracting(previousQContext)
            let derivative = try deltaQ.multiplied(by: step.method == .backwardEuler ? one : two).divided(by: interval)
            let iq = try derivative.subtracting(step.method == .trapezoidal ? previousIq : zero)
            let residual = try voltage.multiplied(by: voltage).subtracting(one).adding(iq)
            #expect(residual.absoluteUpperBound <= 1e-12)
            previous = voltage; previousTime = time; previousIq = iq
        }
    }

    @Test func pilotBULKOriginalTransientUsesActualPrecisionWorker() async throws { try await pilot("bsim-n-loaded-s4-transient") }
    @Test func pilotCMGOriginalTransientUsesActualPrecisionWorker() async throws { try await pilot("cmg-n-loaded-s4-transient") }
    @Test func pilotIMGThermalTransientUsesActualPrecisionWorker() async throws { try await pilot("img-n-thermal-s4-transient") }
    @Test func pilotSOIThermalTransientUsesActualPrecisionWorker() async throws { try await pilot("soi-n-series-thermal-s4-transient") }

    @Test func setupOptionsAndSelectedBitsRemainPartOfExactConfiguration() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let baseline = try await preparationIdentity(fixture)
        let given = try OSDIParameterAssignment(name: "$mfactor", scope: .model, value: .real(0.5))
        let setup = try await preparationIdentity(fixture, parameter: given)
        #expect(setup.configuration != baseline.configuration)
        #expect(setup.program == baseline.program && setup.setup != baseline.setup)
        let alteredOptions = try fixture.changingOptions(workUnits: fixture.options.maximumWorkUnits + 1)
        let policy = try await preparationIdentity(fixture, precision: fixture.precision(options: alteredOptions))
        #expect(policy.configuration != baseline.configuration)
        let bits = try await preparationIdentity(fixture, precision: fixture.precision(bits: 128))
        #expect(bits.configuration != baseline.configuration)
    }

    @Test func changedWorkerAndSemanticIdentityAndProgramBudgetRefuseWithoutOrdinaryFallback() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let wrong = try ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "0", count: 64))
        for kind in ["semantic", "worker", "programBudget"] {
            let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
            let input = try await fixture.input()
            let precision: OSDITransientPrecisionInputs
            switch kind {
            case "semantic": precision = try fixture.precision(semantic: wrong)
            case "worker":
                let reference = try ArtifactReference(digest: wrong, byteCount: fixture.worker.expectedReference.byteCount,
                    descriptor: fixture.worker.expectedReference.descriptor)
                guard case .local(_, let rootID, let path) = fixture.worker.availability else {
                    Issue.record("Expected local worker input"); return
                }
                let worker = try ArtifactAccessIntent(expectedReference: reference,
                    availability: .local(artifactID: reference.id, rootID: rootID, relativePath: path), operation: .read,
                    budget: fixture.worker.budget)
                precision = try fixture.precision(worker: worker)
            default: precision = try fixture.precision(options: fixture.changingOptions(programBytes: 1))
            }
            do {
                let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
                    osdi: fixture.runtime(provider: tracked, precision: precision))
                try prepared.close()
                Issue.record("Changed precision identity/budget was admitted: \(kind)")
            } catch SPICENativePreparationError.osdi(.runtime(let failure)) {
                switch (kind, failure) {
                case ("semantic", .identityMismatch): break
                case ("worker", .artifact(.contentDigestMismatch)): break
                case ("programBudget", .native(let issue)): #expect(issue.code == 7 && issue.field == "precision")
                default: throw failure
                }
            }
            #expect(tracked.count == 1)
            try tracked.expectClosed()
        }
    }

    @Test func numericProfileCannotReuseAnUnchangedConfiguration() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let baseline = try await preparationIdentity(fixture)
        let changed = try ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "0", count: 64))
        do {
            let actual = try await preparationIdentity(fixture, precision: fixture.precision(numeric: changed))
            #expect(actual.configuration != baseline.configuration)
        } catch SPICENativePreparationError.osdi(.runtime(.precision(let issue))) {
            #expect(issue.code != .timeout && issue.code != .cleanupFailure)
        }
    }

    @Test func missingModelCapabilityAndUnsupportedMixedDeviceNeverPublishPreparedPrecision() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let ordinary = try OSDIAnalysisNativeFixture()
        defer { do { try ordinary.base.close() } catch { Issue.record("Ordinary fixture cleanup failed") } }
        let point = try #require(ordinary.manifest.cases.first { $0.id == "analytic-uic-rc" })
        let input = try await ordinary.input(point, resources: fixture.resources())
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: ordinary.base.provider)
        do {
            let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
                osdi: fixture.runtime(point, provider: tracked))
            try prepared.close(); Issue.record("An ordinary-only model was admitted to precision")
        } catch SPICENativePreparationError.osdi(.runtime(.native(let issue))) {
            #expect(issue.code == 12 && issue.field == "precision")
        }
        try tracked.expectClosed()
        let mixed = try await fixture.input(unsupportedMixedDevice: true)
        do {
            let prepared = try await SPICENativeSimulation().prepare(mixed, limits: fixture.limits, osdi: fixture.runtime())
            try prepared.close(); Issue.record("A mixed unsupported contributor was admitted")
        } catch SPICENativePreparationError.unsupportedCapability {}
    }

    @Test func cancelledPreparedPrecisionClosesWorkerAndLibraryWithoutCompletedOutput() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let input = try await fixture.input()
        let baseline = try FileManager.default.contentsOfDirectory(atPath: fixture.analysis.base.directory.path).sorted()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: fixture.runtime(provider: tracked))
        let cancellation = CancellationToken(); cancellation.cancel()
        do { _ = try await native.execute(prepared, cancellation: cancellation); Issue.record("Cancelled precision completed") }
        catch SPICENativeExecutionError.cancelled {}
        #expect(tracked.count == 1)
        try tracked.expectClosed()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.analysis.base.directory.path).sorted() == baseline)
    }

    private func preparationIdentity(_ fixture: OSDIPrecisionNativeFixture, parameter: OSDIParameterAssignment? = nil,
        precision: OSDITransientPrecisionInputs? = nil) async throws
        -> (configuration: ContentDigest, program: ContentDigest, setup: ContentDigest) {
        let input = try await fixture.input(parameter: parameter)
        let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits, osdi: fixture.runtime(precision: precision))
        defer { do { try prepared.close() } catch { Issue.record("Preparation inspection cleanup failed") } }
        let inspection = prepared.record
        let receipt = try #require(inspection.osdiPreparationRecords.first?.transientPrecision)
        return (prepared.configurationIdentity, receipt.program.programDigest, receipt.program.setupDigest)
    }

    private func pilot(_ id: String) async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Precision fixture cleanup failed") } }
        let point = try #require(fixture.analysis.manifest.cases.first { $0.id == id })
        let input = try await fixture.pilotInput(point)
        let native = SPICENativeSimulation()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: fixture.runtime(point, provider: tracked))
        let output = try await native.execute(prepared, cancellation: .init())
        let device = try #require(point.input.circuit.devices.first)
        try checkEvidence(output, fixture: fixture, modelID: device.library)
        let result = try #require(output.transientResult)
        #expect(output.phases.map(\.analysis) == ["op", "tran"])
        #expect(output.phases.map(\.completedPointCount) == [1, result.timePoints.count])
        for phase in output.phases {
            let rows = try #require(phase.equationPolicy).rows
            for row in rows {
                let key = row.kind == .thermalPotential ? "W" : row.kind == .electricalFlow ? "V" : "A"
                #expect(row.equationAbsoluteTolerance == point.input.circuit.policy.equationAbsoluteTolerances[key])
            }
        }
        #expect(fixture.preparer.snapshotCount == 1 && fixture.preparer.launchCount == 1)
        try tracked.expectClosed()
        print("Native precision pilot \(id): \(result.acceptedSteps.count) accepted, \(result.timePoints.count) full paired points, \(result.solutionTrace.variableCount) rows")
    }

    private func checkEvidence(_ output: SPICENativeSimulationOutput, fixture: OSDIPrecisionNativeFixture, modelID: String) throws {
        let model = try #require(fixture.manifest.models.first { $0.id == modelID })
        let record = try #require(output.prepared.osdiPreparationRecords.first)
        let receipt = try #require(record.transientPrecision)
        #expect(receipt.program.modelReference == record.receipt.resolved.binding.artifact)
        #expect(receipt.program.modelReference.digest.hexadecimalValue == model.sha256)
        #expect(receipt.program.programDigest.hexadecimalValue == model.program.sha256)
        #expect(UInt64(receipt.program.programBytes.count) == model.program.byteCount)
        #expect(!receipt.program.setupBytes.isEmpty)
        #expect(receipt.workerReference == fixture.worker.expectedReference)
        #expect(receipt.program.semanticProfile.hexadecimalValue == fixture.manifest.semanticProfileSHA256)
        #expect(receipt.numericProfile.hexadecimalValue == fixture.manifest.numericProfileSHA256)
        #expect(receipt.options == fixture.options && receipt.precisionBits == fixture.manifest.precisionBits)
        let result = try #require(output.transientResult)
        let low = try #require(result.solutionLowTrace)
        #expect(low.variableCount == result.solutionTrace.variableCount && low.pointCount == result.timePoints.count)
        #expect(result.acceptedSteps.count == result.timeSteps && result.timeSteps + 1 == result.timePoints.count)
        for point in result.timePoints.indices {
            try result.withCompensatedSolution(at: point) { high, low in
                let low = try #require(low)
                for row in high.indices { _ = try CompensatedValue(high: high[row], low: low[row]) }
            }
        }
        for (index, step) in result.acceptedSteps.enumerated() {
            let interval = try CompensatedValue(high: result.timePoints[index + 1]).subtracting(CompensatedValue(high: result.timePoints[index]))
            #expect(try interval == CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent))
        }
    }

    private func checkOriginalCompound(_ result: TransientResult) throws {
        let first = try result.checkedCompensatedValue(variableIndex: 0, timeIndex: 1)
        #expect(first.high == 1 && first.low > 0)
        var previousOffset = 0.0, previousIq = 0.0
        for (index, step) in result.acceptedSteps.enumerated() {
            let value = try result.checkedCompensatedValue(variableIndex: 0, timeIndex: index + 1)
            let offset = (value.high - 1) + value.low
            let iq = (step.method == .backwardEuler ? 1.0 : 2.0) * 1e-9 * (offset - previousOffset)
                / (step.timeStep + step.timeStepLowComponent) - (step.method == .trapezoidal ? previousIq : 0)
            #expect(abs(2 * offset + offset * offset - 0x1p-30 + iq) <= 1e-12)
            previousOffset = offset; previousIq = iq
        }
    }
}
