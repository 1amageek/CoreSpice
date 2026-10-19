import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceMOSContracts
import CoreSpiceParser
import CoreSpiceEvaluationContracts
import CoreSpiceLowering
@testable import CoreSpice
@testable import CoreSpiceIO
import Testing
import Synchronization

@Suite("Release fresh source reexecution", .timeLimit(.minutes(1)))
struct ReleaseSourceReexecutionTests {
    @Test func parameterSweepUsesFreshSourceResolutionAndPreservesOriginal() async throws {
        let original = try await PreparedNativeExecutionTests().input("""
        Source parameter sweep
        .param resistance=1k
        V1 in 0 2
        R1 in out {resistance}
        R2 out 0 1k
        .op
        .end
        """)
        let changed = try SPICESimulationPreparer().reprepare(original, parameterOverrides: ["resistance": 3000])
        #expect(original.sourceInputIdentity == changed.sourceInputIdentity)
        #expect(original.configuration.identity != changed.configuration.identity)
        let first = try await execute(original)
        let second = try await execute(changed)
        #expect(abs(try voltage(first, "out") - 1) < 1e-9)
        #expect(abs(try voltage(second, "out") - 0.5) < 1e-9)
        #expect(changed.lowered.evaluationProvenance.seed == original.lowered.evaluationProvenance.seed)
        let repeated = try SPICESimulationPreparer().reprepare(changed)
        #expect(repeated.configuration.identity == changed.configuration.identity)
        let third = try await execute(repeated)
        #expect(abs(try voltage(third, "out") - 0.5) < 1e-9)
    }

    @Test func temperatureSweepReevaluatesSourceExpressionsAndKeepsNominalAuthority() async throws {
        let original = try await PreparedNativeExecutionTests().input("""
        Source temperature sweep
        .temp 27
        .options tnom=20
        V1 out 0 {temper}
        R1 out 0 1k
        .op
        .end
        """)
        let ambient = try TemperatureCelsius(77).kelvin
        let nominal = try TemperatureCelsius(20).kelvin
        let changed = try SPICESimulationPreparer().reprepare(original,
            temperaturePolicy: .init(defaults: .init(ambient: ambient, nominal: nominal), ambientOverride: ambient))
        #expect(changed.configuration.temperatureCelsius == 77)
        #expect(changed.configuration.nominalTemperatureCelsius == 20)
        #expect(changed.configuration.temperatureOrigin == "caller-override")
        #expect(changed.sourceInputIdentity == original.sourceInputIdentity)
        #expect(changed.configuration.identity != original.configuration.identity)
        let first = try await execute(original)
        let second = try await execute(changed)
        #expect(abs(try voltage(first, "out") - 27) < 1e-8)
        #expect(abs(try voltage(second, "out") - 77) < 1e-8)
    }

    @Test func mosSensitivityUsesRawSourceUnitsAndFreshReceipts() async throws {
        let input = try await PreparedNativeExecutionTests().input("""
        MOS source sensitivity
        VDD supply 0 1
        VG gate 0 1
        R1 supply drain 1k
        .model n NMOS level=1 vto=.4 kp=1e-4
        M1 drain gate 0 0 n l=1 w=10
        .options scale=1u
        .sens V(drain)
        .end
        """)
        let mosName = try #require(input.circuit.instances.first(where: { $0.mos != nil })?.name)
        #expect(mosName == "m1")
        #expect(input.lowered.evaluationProvenance.sourceScalars.contains {
            $0.instanceName == mosName && $0.role == .instance && $0.parameterName == "w" && $0.value == 10
        })
        let prepared = try SPICENativeSimulation().prepare(input, limits: PreparedNativeExecutionTests().mosLimits())
        let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
        let result = try #require(output.sensitivityResult)
        let width = try #require(result.sensitivities.first { $0.deviceName == mosName && $0.parameterName == "instance.w" })
        #expect(width.nominalValue == 10)
        // The admitted Level 1 channel smooths the overdrive by 25 mV even in saturation.
        let overdrive = 0.5 * (0.6 + (0.6 * 0.6 + 0.025 * 0.025).squareRoot())
        let currentPerKP = 0.5 * 10 * overdrive * overdrive
        #expect(abs(width.sensitivity + 1000 * 1e-4 * currentPerKP / 10) < 1e-8)
        #expect(abs(result.baselineValue - (1 - 1000 * 1e-4 * currentPerKP)) < 1e-8)
        let coefficient = try #require(result.sensitivities.first { $0.deviceName == mosName && $0.parameterName == "model.kp" })
        #expect(abs(coefficient.sensitivity + 1000 * currentPerKP) < 1e-3)
        let child = try #require(coefficient.perturbedOutput)
        let replacement = try #require(coefficient.perturbedValue)
        #expect(abs(child.high + child.low - (1 - 1000 * replacement * currentPerKP)) < 1e-8)
        let ledger = try #require(output.phases.compactMap(\.sourceReexecutionLedger).first)
        #expect(ledger.records.count == result.sensitivities.count)
        #expect(ledger.records.allSatisfy { $0.sourceInputIdentity == input.sourceInputIdentity })
        #expect(ledger.records.allSatisfy { $0.preparation.mosPreparationReceipts.count == 1 })
        #expect(ledger.records.allSatisfy { $0.preparation.mosPreparationReceipts[0].coldSetupCount == 1 })
        #expect(ledger.records.contains { $0.sourceOverrides.contains { $0.instanceName == mosName && $0.parameterName == "w" } })
        #expect(output.statistics.solveAttempts > result.sensitivities.count)
    }

    @Test func preparedTransferAndPoleZeroRetainNumericalResults() async throws {
        let tf = try await PreparedNativeExecutionTests().input("Transfer\nV1 in 0 2\nR1 in out 1k\nR2 out 0 1k\n.tf V(out) V1\n.end\n")
        let transfer = try await execute(tf)
        #expect(abs(try #require(transfer.tfResult).gain - 0.5) < 1e-9)
        let pz = try await PreparedNativeExecutionTests().input("Pole\nV1 in 0 1\nR1 in out 1k\nC1 out 0 1u\n.pz in 0 out 0 vol pz\n.end\n")
        let poleOutput = try await execute(pz)
        let poles = try #require(poleOutput.poleZeroResult)
        #expect(poles.poles.contains { abs($0.real + 1000) < 1e-6 && abs($0.imag) < 1e-9 })
    }

    @Test func temperatureAndMonteCarloFamilyShareCaptureAndReevaluateSeeds() async throws {
        let resources = SourceBoundaryTestResources()
        let text = """
        Source family
        .param resistance={1000+100*rand()}
        V1 in 0 2
        R1 in out {resistance}
        R2 out 0 1k
        .temp 27 77
        .mc 2 dc V1 1 2 1 seed=17
        .end
        """
        let request = try request(text, resources: resources)
        let family = try await SPICESimulationPreparer().prepareRuns(request, resources: resources)
        #expect(family.selections.count == 4)
        #expect(family.selections.map(\.seed) == [17, 18, 17, 18])
        #expect(family.selections.map { $0.temperatureSelection?.celsius } == [27, 27, 77, 77])
        var values: [Double] = []
        var identities: [ContentDigest] = []
        for index in family.selections.indices {
            let input = try family.prepareRun(at: index)
            #expect(input.sourceInputIdentity == family.sourceInputIdentity)
            #expect(input.configuration.seed == family.selections[index].seed)
            #expect(input.lowered.evaluationProvenance.randomDraws > 0)
            let output = try await execute(input)
            values.append(try voltage(output, "out")); identities.append(output.configurationIdentity)
        }
        #expect(values[0] != values[1])
        #expect(values[0] == values[2] && values[1] == values[3])
        #expect(Set(identities).count == 4)
        let repeated = try family.prepareRun(at: 0)
        let output = try await execute(repeated)
        #expect(try voltage(output, "out") == values[0])
        let overrideRequest = try self.request(text, resources: resources, monteCarloSeedOverride: 99)
        let overridden = try await SPICESimulationPreparer().prepareRuns(overrideRequest, resources: resources)
        #expect(overridden.selections.map(\.seed) == [99, 100, 99, 100])
        #expect(overridden.selections.allSatisfy { $0.monteCarloSeedOrigin == .callerOverride })
        #expect(family.selections.allSatisfy { $0.monteCarloSeedOrigin == .sourceDirective })
    }

    @Test func preparedFourierUsesTheSourceTransientAndRetainsItsResult() async throws {
        let input = try await PreparedNativeExecutionTests().input("""
        Fourier source
        V1 out 0 SIN(0 1 1k)
        R1 out 0 1k
        .tran 10u 2m
        .four 1k V(out)
        .end
        """, index: 1)
        let output = try await execute(input)
        let result = try #require(output.fourierResult)
        let harmonics = try #require(result.harmonics.values.first)
        let fundamental = try #require(harmonics.first { $0.harmonic == 1 })
        #expect(abs(fundamental.magnitude - 1) < 0.003)
        #expect(result.transientResult.timePoints.last == 0.002)
        #expect(output.transientResult?.timePoints == result.transientResult.timePoints)
    }

    @Test func failedFreshResolutionReleasesReservationsAndPreservesOriginal() async throws {
        let resources = SourceBoundaryTestResources()
        let original = try await PreparedNativeExecutionTests().input("Failure\n.param resistance=1k\nV1 out 0 1\nR1 out 0 {resistance}\n.op\n.end\n", resources: resources)
        let retained = resources.used(.liveOwnedBytes)
        #expect(throws: SPICESimulationPreparationError.self) {
            _ = try SPICESimulationPreparer().reprepare(original, parameterOverrides: ["resistance": .nan])
        }
        #expect(resources.used(.liveOwnedBytes) == retained)
        #expect(resources.used(.temporaryBytes) == 0)
        resources.setCancelled(true)
        #expect(throws: SPICESimulationPreparationError.self) {
            _ = try SPICESimulationPreparer().reprepare(original, parameterOverrides: ["resistance": 2000])
        }
        #expect(resources.used(.liveOwnedBytes) == retained)
        resources.setCancelled(false)
        let output = try await execute(original)
        #expect(abs(try voltage(output, "out") - 1) < 1e-9)
    }

    private final class FreshPreparationFailureResources: SPICESourceResourceAccounting {
        private struct State { var armed = false; var freshScratch = false; var injected = false }
        private let state = Mutex(State())
        let original: SourceBoundaryTestResources
        let cancellation: CancellationToken
        let unrelatedFailure: Bool
        init(original: SourceBoundaryTestResources, cancellation: CancellationToken, unrelatedFailure: Bool) {
            self.original = original; self.cancellation = cancellation; self.unrelatedFailure = unrelatedFailure
        }
        func arm() { state.withLock { $0.armed = true } }
        var injected: Bool { state.withLock { $0.injected } }
        func checkCancellation() throws { try original.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            let inject = state.withLock { value -> Bool in
                guard value.armed, value.freshScratch, !value.injected else { return false }
                value.injected = true; return true
            }
            if inject {
                if unrelatedFailure {
                    cancellation.cancel()
                    throw SourceBoundaryTestError.workLimit
                }
                throw CancellationError()
            }
            try original.charge(kind, units: units)
        }
        func chargeHashedBytes(_ count: UInt64) throws { try original.chargeHashedBytes(count) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            let reservation = try original.reserveStorage(kind: kind, byteCount: byteCount)
            if kind == .temporaryBytes { state.withLock { if $0.armed { $0.freshScratch = true } } }
            return reservation
        }
    }

    private struct ArmAfterBaseline: AnalysisObserver {
        let resources: FreshPreparationFailureResources
        func onEvent(_ event: AnalysisEvent) {
            if case .analysisFinished(let info) = event, info.type == .dc, info.status == .completed { resources.arm() }
        }
    }

    @Test(arguments: [false, true])
    func freshPreparationCancellationRetainsTheActualCauseAndReleasesStorage(unrelatedFailure: Bool) async throws {
        let resources = SourceBoundaryTestResources()
        let input = try await PreparedNativeExecutionTests().input("Cancelled fresh source\nV1 in 0 2\nR1 in out 1k\nR2 out 0 1k\n.sens V(out)\n.end\n",
            resources: resources)
        let retained = resources.used(.liveOwnedBytes)
        let cancellation = CancellationToken()
        let failing = FreshPreparationFailureResources(original: resources, cancellation: cancellation, unrelatedFailure: unrelatedFailure)
        let buffered = try BufferingObserver(capacity: 1000)
        let invocation = try AnalysisExecutionResources(limits: input.configuration.numericalLimits)
        do {
            let controlled = input.checkingResources(failing)
            let limits = SPICENativeExecutionLimits(maximumDeviceCount: 32, maximumMatrixDimension: 32,
                maximumAllocationBytes: 16 * 1024 * 1024)
            let native = try SPICENativeSimulation().prepare(controlled, limits: limits)
            let binding = try NativeSourceCircuitDeviceBinding(input: controlled, limits: limits,
                maximumReexecutions: NativeSourceCircuitDeviceBinding.sensitivityCapacity(controlled),
                cancellation: cancellation, baselinePreparation: native.record.circuitPreparation)
            guard case .sensitivity(let outputNode, _) = controlled.configuration.analysis else {
                Issue.record("Missing source sensitivity"); return
            }
            do {
                let circuit = try native.takeCircuit().usingExecutionResources(invocation)
                _ = try await SensitivityAnalysis(outputNode: outputNode, deviceBinding: binding).run(circuit: circuit,
                    solver: SparseLUSolver(), observer: EventDispatcher(observers: [ArmAfterBaseline(resources: failing), buffered]),
                    cancellation: cancellation)
                Issue.record("Failed fresh preparation published a completed sensitivity result")
            } catch SPICENativeExecutionError.cancelled {
                #expect(!unrelatedFailure)
            } catch SPICENativeExecutionError.numerical(let cause) {
                #expect(unrelatedFailure)
                guard case SPICESimulationPreparationError.resolution(_, let resourceCause) = cause else { throw cause }
                #expect(resourceCause as? SourceBoundaryTestError == .workLimit)
            }
        }
        #expect(failing.injected)
        #expect(cancellation.isCancelled == unrelatedFailure)
        // The baseline is physically solved; injection occurs in fresh frontend work before any child solve.
        #expect(invocation.usage.solveAttempts == 2)
        #expect(resources.used(.liveOwnedBytes) == retained)
        #expect(resources.used(.temporaryBytes) == 0)
        let terminal = buffered.events.compactMap { event -> AnalysisFinishedInfo? in
            if case .analysisFinished(let info) = event { return info }; return nil
        }
        #expect(terminal.filter { $0.type == .dc && $0.status == .completed }.count == 1)
        let sensitivity = terminal.filter { $0.type == .sens }
        #expect(sensitivity.count == 1)
        #expect(sensitivity.first?.status == (unrelatedFailure ? .failed : .cancelled))
    }

    @Test func nativeSourceRunsShareInvocationNumericalCeilings() async throws {
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 100, maximumSolveAttempts: 2,
            maximumNewtonIterations: 1000, maximumSavedScalars: 1000, maximumMatrixDimension: 32,
            maximumWorkUnits: 1000000, maximumBreakpoints: 100)
        let resources = SourceBoundaryTestResources()
        let request = try request("Invocation\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n",
            resources: resources, numerical: limits)
        let input = try await SPICESimulationPreparer().prepare(request, resources: resources)
        let invocation = try AnalysisExecutionResources(limits: limits)
        let native = SPICENativeExecutionLimits(maximumDeviceCount: 32, maximumMatrixDimension: 32,
            maximumAllocationBytes: 16 * 1024 * 1024)
        let first = try await SPICENativeSimulation().execute(SPICENativeSimulation().prepare(input, limits: native),
            cancellation: .init(), executionResources: invocation)
        #expect(first.statistics.solveAttempts == 2)
        #expect(invocation.usage.solveAttempts == 2)
        do {
            _ = try await SPICENativeSimulation().execute(SPICENativeSimulation().prepare(input, limits: native),
                cancellation: .init(), executionResources: invocation)
            Issue.record("The second source case reset the invocation solve ceiling")
        } catch SPICENativeExecutionError.numerical(let cause) {
            guard case TransientExecutionError.limitExceeded(let resource, let limit, let requested) = cause else { throw cause }
            #expect(resource == "invocation.solveAttempts" && limit == 2 && requested == 3)
        }
        #expect(invocation.usage.solveAttempts == 2)
        #expect(abs(try voltage(first, "out") - 1) < 1e-9)
    }

    private struct EmptyProvider: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }

    private func request(_ text: String, resources: SourceBoundaryTestResources, numerical: TransientExecutionLimits? = nil,
                         monteCarloSeedOverride: UInt64? = nil) throws -> SPICESimulationPreparationRequest {
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
            }
        let binding = SPICEExactSourceBinding(key: "source-family", reference: try .init(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let source = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 64)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "release-family-v1", configuration: parser,
            resources: resources, maximumPageByteCount: 64)
        return try .init(root: source, environment: environment, catalog: [binding], routes: [], provider: EmptyProvider(),
            configuration: parser, operatingPolicy: .recordActual,
            limits: .init(maximumElements: 512, maximumTransformBytes: 8 * 1024 * 1024, maximumSweepPoints: 100,
                maximumPageByteCount: 64, numerical: numerical ?? .init(maximumAcceptedSteps: 5000, maximumSolveAttempts: 10000,
                    maximumNewtonIterations: 50000, maximumSavedScalars: 50000, maximumMatrixDimension: 32,
                    maximumWorkUnits: 100000000, maximumBreakpoints: 1000)),
            profile: .coreStrictV1, seed: 42, resolutionLimits: PreparedNativeExecutionTests().resolutionLimits(),
            monteCarloSeedOverride: monteCarloSeedOverride)
    }

    private func execute(_ input: PreparedSPICESimulation) async throws -> SPICENativeSimulationOutput {
        let prepared = try SPICENativeSimulation().prepare(input,
            limits: .init(maximumDeviceCount: 32, maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024))
        return try await SPICENativeSimulation().execute(prepared, cancellation: .init())
    }

    private func voltage(_ result: SPICENativeSimulationOutput, _ name: String) throws -> Double {
        let index = try #require(result.waveform.variables.firstIndex { $0.name.lowercased() == "v(\(name))" })
        return try #require(result.waveform.realValue(variable: index, point: 0))
    }
}
