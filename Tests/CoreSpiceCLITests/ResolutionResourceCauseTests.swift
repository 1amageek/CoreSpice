import CoreSpiceDiodeContracts
import CoreSpiceIO
import CoreSpiceMOSResolution
import Synchronization
import Testing
@testable import CoreSpiceCLICore

@Suite("CLI wrapped frontend resource causes", .timeLimit(.minutes(1)))
struct ResolutionResourceCauseTests {
    private final class ReleaseCounter: Sendable {
        let value = Mutex(0)
    }
    /// Selects the actual evaluation boundary without consuming the host budget during setup.
    private final class ArmedControl: MOSResolutionControlling {
        let host: CoreSpiceCLIResolutionControl
        let retainedBytes: UInt64?
        private let armed = Mutex(false)

        init(host: CoreSpiceCLIResolutionControl, retainedBytes: UInt64? = nil) {
            self.host = host; self.retainedBytes = retainedBytes
        }
        func arm() { armed.withLock { $0 = true } }
        func checkCancellation() throws(MOSResolutionFailure) {
            if armed.withLock({ $0 }) { try host.checkCancellation() }
        }
        func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
            guard armed.withLock({ $0 }) else { return }
            if let retainedBytes {
                guard kind == .retainedBytes, units == retainedBytes else { return }
            }
            try host.charge(kind, units: units)
        }
    }

    private func hostControl() throws -> CoreSpiceCLIResolutionControl {
        CoreSpiceCLIResolutionControl(resources: try .init(maximumLiveBytes: 1024,
            maximumTemporaryBytes: 1024, maximumWorkUnits: 1, maximumHashedBytes: 1024), cancellation: nil)
    }

    @Test func actualTemperatureBootstrapPreservesInjectedSharedWorkCause() throws {
        let limits = try CoreSpiceCLIExecutionPolicy.developerV1().resolutionLimits
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let scope = try builder.addScope(parent: nil)
        let snapshot = try builder.finish()
        let invocation = try MOSScopeInvocation(id: 0, scope: scope,
            callerInvocationID: nil, actuals: [], limits: limits)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [invocation], limits: limits)
        let host = try hostControl()
        let control = ArmedControl(host: host)
        let bootstrap = try MOSEvaluationBootstrapSession(snapshot: snapshot, graph: graph,
            seed: 1, limits: limits, control: control)
        control.arm()
        do {
            _ = try bootstrap.freeze(ambient: .temperature(.init(300.15)), nominal: .temperature(.init(300.15)))
            Issue.record("Temperature bootstrap ignored the shared work refusal")
        } catch let failure as MOSConditionEvaluationFailure {
            #expect(failure.cause == .limitExceeded(.retainedBytes))
            let preserved = host.preservingResourceCause(failure)
            guard case .condition(let condition, let cause) = preserved as? SPICESimulationPreparationError else {
                Issue.record("Temperature wrapper lost the original shared resource cause")
                return
            }
            #expect(condition.cause == failure.cause)
            #expect(condition.diagnostic?.cause == failure.diagnostic?.cause)
            #expect(condition.diagnostic?.conditionSource == failure.diagnostic?.conditionSource)
            #expect(cause as? SPICESimulationResources.ResourceError == .workLimit)
            #expect(CoreSpiceCLIFailure(error: preserved).code == "invocation.work-limit")
        }
    }

    @Test func actualDiodeResolutionPreservesSharedWorkCauseAndDiagnosticLease() async throws {
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        let deck = try await SPICEDeckLoader.load(source: """
        Diode evaluation boundary
        .model dm d(is=1e-14)
        D1 out 0 dm
        .op
        .end
        """)
        let compiled = try NetlistLowering.compile(deck.netlist, limits: policy.resolutionLimits)
        let host = try hostControl()
        // This charge belongs to DiodeResolver after model selection, before model construction.
        let control = ArmedControl(host: host, retainedBytes: ResolvedDiodeModel.ownedByteCount)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: policy.profile,
            limits: policy.resolutionLimits, seed: 1, control: control)
        control.arm()
        do {
            try session.lower(diodeProfile: policy.diodeProfile)
            Issue.record("Diode evaluation ignored the shared work refusal")
        } catch let failure as DiodeResolutionFailure {
            #expect(failure.cause == .evaluation(.limitExceeded(.retainedBytes)))
            let releases = ReleaseCounter()
            var lease: SPICESourceStorageReservation? = .init(kind: .liveOwnedBytes, byteCount: 17) {
                releases.value.withLock { $0 += 1 }
            }
            var wrapped: SPICESimulationPreparationError? = .diodeResolution(failure,
                resourceCause: nil, reservation: lease)
            lease = nil
            var preserved: (any Error)? = host.preservingResourceCause(try #require(wrapped))
            wrapped = nil
            #expect(releases.value.withLock { $0 } == 0)
            do {
                guard case .diodeResolution(let diode, let cause, let retained) = preserved as? SPICESimulationPreparationError else {
                    Issue.record("Diode wrapper changed category")
                    return
                }
                #expect(diode.cause == failure.cause)
                #expect(diode.instance == failure.instance && diode.assignmentIndex == failure.assignmentIndex)
                #expect(retained?.byteCount == 17)
                #expect(cause as? SPICESimulationResources.ResourceError == .workLimit)
                #expect(CoreSpiceCLIFailure(error: try #require(preserved)).code == "invocation.work-limit")
            }
            preserved = nil
            #expect(releases.value.withLock { $0 } == 1)
        }
    }

    @Test(arguments: [false, true])
    func ordinaryTemperatureAndDiodeFailuresKeepTheirCategories(hasPriorResourceFailure: Bool) async throws {
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        let host = try hostControl()
        if hasPriorResourceFailure {
            #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
                try host.charge(.retainedBytes, units: 2)
            }
        }
        #expect(host.preservingResourceCause(MOSResolutionFailure.invalidRequest) as? MOSResolutionFailure == .invalidRequest)
        let temperature = try await SPICEDeckLoader.load(source: "Temperature cycle\n.temp {temper}\n.op\n.end\n")
        let temperatureCompiled = try NetlistLowering.compile(temperature.netlist, limits: policy.resolutionLimits)
        do {
            _ = try NetlistLowering.beginEvaluation(temperatureCompiled, profile: policy.profile,
                limits: policy.resolutionLimits, seed: 1)
            Issue.record("Cyclic temperature was accepted")
        } catch let failure as MOSConditionEvaluationFailure {
            let preserved = host.preservingResourceCause(failure)
            #expect((preserved as? MOSConditionEvaluationFailure)?.cause == .conditionCycle(.ambient))
            #expect(CoreSpiceCLIFailure(error: preserved).code == "evaluation.temperature")
        }
        let diode = try await SPICEDeckLoader.load(source: "Missing diode model\nD1 out 0 absent\n.op\n.end\n")
        let diodeCompiled = try NetlistLowering.compile(diode.netlist, limits: policy.resolutionLimits)
        var session = try NetlistLowering.beginEvaluation(diodeCompiled, profile: policy.profile,
            limits: policy.resolutionLimits, seed: 1)
        do {
            try session.lower(diodeProfile: policy.diodeProfile)
            Issue.record("Missing diode model was accepted")
        } catch let failure as DiodeResolutionFailure {
            let wrapped = SPICESimulationPreparationError.diodeResolution(failure, resourceCause: nil, reservation: nil)
            let preserved = host.preservingResourceCause(wrapped)
            guard case .diodeResolution(let diode, let cause, _) = preserved as? SPICESimulationPreparationError else {
                Issue.record("Ordinary diode failure changed category")
                return
            }
            #expect(diode.cause == .undefinedModel && cause == nil)
            #expect(CoreSpiceCLIFailure(error: preserved).code == "diode.resolution")
        }
    }
}
