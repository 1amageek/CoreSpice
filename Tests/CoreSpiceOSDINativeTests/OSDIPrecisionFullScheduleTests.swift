import CircuiteFoundation
@testable import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import OSDIContracts
import Testing

/// Each method is separately filterable so the runner bounds one complete schedule.
@Suite("Actual Native precision full original schedules", .serialized, .timeLimit(.minutes(11)))
struct OSDIPrecisionFullScheduleTests {
    @Test func fullBULKNLoaded() async throws { try await run("bsim-n-loaded-s4-transient") }
    @Test func fullBULKPReverseLoaded() async throws { try await run("bsim-p-reverse-loaded-s4-transient") }
    @Test func fullBULKPSelfheatLoaded() async throws { try await run("bsim-p-selfheat-loaded-s4-transient") }
    @Test func fullCMGNLoaded() async throws { try await run("cmg-n-loaded-s4-transient") }
    @Test func fullCMGPReverseLoaded() async throws { try await run("cmg-p-reverse-loaded-s4-transient") }
    @Test func fullCMGNSelfheatSeriesLoaded() async throws { try await run("cmg-n-selfheat-series-loaded-s4-transient") }
    @Test func fullIMGNLoaded() async throws { try await run("img-n-loaded-s4-transient") }
    @Test func fullIMGPReverse() async throws { try await run("img-p-reverse-s4-transient") }
    @Test func fullIMGNThermal() async throws { try await run("img-n-thermal-s4-transient") }
    @Test func fullSOINForward() async throws { try await run("soi-n-forward-s4-transient") }
    @Test func fullSOIPReverse() async throws { try await run("soi-p-reverse-s4-transient") }
    @Test func fullSOINSeriesThermal() async throws { try await run("soi-n-series-thermal-s4-transient") }

    private func run(_ id: String) async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Full schedule fixture cleanup failed") } }
        let point = try #require(fixture.analysis.manifest.cases.first { $0.id == id })
        try #require(point.kind == "transient" && point.expectedOutcome == "passed")
        let requested = try #require(point.input.analysis.steps)
        let first = try #require(requested.first), last = try #require(requested.last)
        try #require(last.timeSeconds > first.timeSeconds)
        // The original source builder uses the complete requested stop; no pilot override.
        let input = try await fixture.analysis.input(point, resources: fixture.resources())
        guard case .transient(let config) = input.configuration.analysis else {
            Issue.record("Original transient input did not produce transient settings"); return
        }
        #expect(config.stopTime.bitPattern == last.timeSeconds.bitPattern)
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.analysis.base.provider)
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: fixture.runtime(point, provider: tracked))
        let inspection = prepared.record
        let committed = try #require(inspection.precisionConfigurationFacts)
        let binding = try #require(inspection.precisionConfigurationBinding)
        let output = try await native.execute(prepared, cancellation: .init())
        try tracked.expectClosed()
        let result = try #require(output.transientResult)
        let lowTrace = try #require(result.solutionLowTrace)
        let width = result.solutionTrace.variableCount
        #expect(result.timePoints.first == 0)
        #expect(result.timePoints.last?.bitPattern == last.timeSeconds.bitPattern)
        #expect(result.timePoints.count == result.timeSteps + 1 && result.acceptedSteps.count == result.timeSteps)
        #expect(result.timeSteps > 0 && result.timeSteps <= input.configuration.numericalLimits.maximumAcceptedSteps)
        #expect(width == inspection.plan.topology.dimension && result.variableMap == inspection.plan.topology.variableMap)
        #expect(lowTrace.variableCount == width && lowTrace.pointCount == result.timePoints.count)
        #expect(committed.settings.transient.stopTime.bitPattern == last.timeSeconds.bitPattern)
        try checkHistory(result, resetTimes: Set((point.input.analysis.stimulus?.points ?? []).map(\.timeSeconds)))
        let expectedPhases = point.input.analysis.initialization == "uic" ? ["tran"] : ["op", "tran"]
        #expect(output.phases.map(\.analysis) == expectedPhases)
        #expect((output.operatingPoint != nil) == (point.input.analysis.initialization != "uic"))
        for phase in output.phases {
            let policy = try #require(phase.equationPolicy)
            #expect(NativePrecisionConfigurationVerification.policiesMatch(policy, committed.equationPolicy))
            #expect(phase.completedPointCount == (phase.analysis == "op" ? 1 : result.timePoints.count))
            for row in policy.rows {
                let unit: String
                switch row.kind {
                case .electricalPotential: unit = "A"
                case .electricalFlow: unit = "V"
                case .thermalPotential: unit = "W"
                }
                #expect(row.equationAbsoluteTolerance == point.input.circuit.policy.equationAbsoluteTolerances[unit])
                if unit == "W" { #expect(row.equationAbsoluteTolerance == 1e-12) }
            }
        }
        // Cold verification happens after model/worker closure. Independent physical
        // replay of the complete saved wire is owned by the CLI/C10 witness.
        try NativePrecisionConfigurationVerification().verify(committed, binding: binding,
            expectedIdentity: output.configurationIdentity, maximumEncodingBytes: 4 * 1024 * 1024,
            resources: SPICESimulationResources(maximumLiveBytes: 4 * 1024 * 1024, maximumTemporaryBytes: 4 * 1024 * 1024,
                maximumWorkUnits: 16 * 1024 * 1024, maximumHashedBytes: 4 * 1024 * 1024))
        #expect(fixture.preparer.snapshotCount == point.input.circuit.devices.count)
        #expect(fixture.preparer.launchCount == point.input.circuit.devices.count)
        print("Native precision full \(id): \(result.acceptedSteps.count) accepted, \(result.rejectedSteps) rejected, \(result.timePoints.count) complete paired points, \(width) rows, stop \(last.timeSeconds)")
    }

    private func checkHistory(_ result: TransientResult, resetTimes: Set<Double>) throws {
        for point in result.timePoints.indices {
            try result.withCompensatedSolution(at: point) { high, low in
                let low = try #require(low)
                #expect(high.count == result.variableMap.count && low.count == high.count)
                for row in high.indices { _ = try CompensatedValue(high: high[row], low: low[row]) }
            }
        }
        for (index, step) in result.acceptedSteps.enumerated() {
            #expect(step.time.bitPattern == result.timePoints[index + 1].bitPattern)
            let interval = try CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent)
            let exact = try CompensatedValue(high: result.timePoints[index + 1]).subtracting(.init(high: result.timePoints[index]))
            #expect(interval == exact)
            if step.previousTimeStep == nil {
                // The audit retains available integration history. Breakpoints
                // intentionally clear that history before checked BE bootstrap.
                #expect(step.method == .backwardEuler && step.previousTimeStepLowComponent == nil)
                if index > 0 {
                    #expect(resetTimes.contains { $0.bitPattern == result.timePoints[index].bitPattern })
                    print("Native full schedule history reset: accepted index \(index), from \(result.timePoints[index]) to \(step.time), method backwardEuler")
                }
            } else {
                try #require(index > 0)
                let previous = result.acceptedSteps[index - 1]
                #expect(step.previousTimeStep?.bitPattern == previous.timeStep.bitPattern)
                #expect(step.previousTimeStepLowComponent?.bitPattern == previous.timeStepLowComponent.bitPattern)
            }
            if index == 0 { #expect(step.previousTimeStep == nil) }
        }
    }
}
