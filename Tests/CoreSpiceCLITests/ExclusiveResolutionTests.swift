import CoreSpice
import CoreSpiceEvent
import CoreSpiceIO
import CoreSpiceMOSContracts
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("CLI exclusive source evaluation", .timeLimit(.minutes(1)))
struct ExclusiveResolutionTests {
    @Test func monteCarloCircuitAndAnalysisShareEachFreshSeedSession() async throws {
        var session = try Session(policy: .developerV1())
        try await session.loadNetlist(source: """
        One scalar session per seed
        .param duration=agauss(1u,.1u,1)
        .model process nmos level=1 vto=.5 kp=1m
        VD d 0 1
        VG g 0 1
        M1 d g 0 0 process l={duration} w=2u
        R1 out 0 1k
        C1 out 0 1n
        .mc 2 tran {duration/duration*.1u} {duration/duration*1u}
        .end
        """, fileName: nil)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        let specification = try #require(session.monteCarloSpec)
        let result = try await session.runMonteCarlo(spec: specification,
            inner: specification.analysis, seedOverride: 42)
        let phases = try #require(session.phaseCollector).phases
        #expect(result.runs.count == 2)
        #expect(phases.count == 2)
        var lengths: [Double] = []
        for (index, run) in result.runs.enumerated() {
            let receipt = try #require(phases[index].facts.mosPreparationReceipts.first)
            let length = try #require(receipt.identity.resolved.normalizedGeometry.length)
            lengths.append(length)
            #expect(receipt.coldSetupCount == 1)
            #expect(phases[index].id == "mc-seed:\(42 + index):tran")
            #expect(try #require(run.waveform.sweepValues.last) == 1e-6)
            #expect(run.waveform.sweepValues == result.runs[0].waveform.sweepValues)
        }
        #expect(lengths[0] != lengths[1])
    }

    @Test func variableSeedSchedulesRefuseCommonAxisPublication() async throws {
        var session = try Session(policy: .developerV1())
        try await session.loadNetlist(source: """
        Distinct seed schedules
        .param duration=agauss(1u,.1u,1)
        .model process nmos level=1 vto=.5 kp=1m
        VD d 0 1
        VG g 0 1
        M1 d g 0 0 process l={duration} w=2u
        R1 out 0 1k
        C1 out 0 1n
        .mc 2 tran {duration/10} {duration}
        .end
        """, fileName: nil)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        let specification = try #require(session.monteCarloSpec)
        do {
            _ = try await session.runMonteCarlo(spec: specification,
                inner: specification.analysis, seedOverride: 42)
            Issue.record("Different seed axes produced a successful common-axis ensemble")
        } catch let error as ParametricWaveformValidationError {
            switch error {
            case .pointCountMismatch(let run, _, _), .sweepValueMismatch(let run, _, _, _):
                #expect(run == 1)
            default:
                Issue.record("Expected an axis mismatch, got \(error)")
            }
            #expect(session.lastParametric == nil)
            #expect(session.lastWaveform == nil)
            #expect(!((session.phaseCollector?.isComplete) ?? true))
        }
    }

    @Test func frontendInitialConditionAndAnalysisReuseEachSeedBinding() async throws {
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        let deck = try await SPICEDeckLoader.load(source: """
        Frontend scalar identity
        .param duration=agauss(1u,.1u,1)
        .model process nmos level=1 vto=.5 kp=1m
        VD d 0 1
        VG g 0 1
        M1 d g 0 0 process l={duration} w=2u
        R1 out 0 1k
        C1 out 0 1n
        .ic V(out)={duration/1u}
        .tran {duration/10} {duration} uic
        .end
        """, fileName: nil)
        let compiled = try NetlistLowering.compile(deck.netlist, limits: policy.resolutionLimits)
        var lengths: [Double] = []
        for seed in [UInt64(42), UInt64(43)] {
            let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
                seed: seed, selectedAnalysisIndex: 0)
            let instance = try #require(values.lowered.circuit.instances.first { $0.name.lowercased() == "m1" })
            guard case .resolved(let resolved) = instance.mos,
                  case .transient(let analysis) = values.analyses[0],
                  case .numeric(let stop) = analysis.stopTime else {
                Issue.record("Frontend did not retain resolved MOS and numeric transient values")
                return
            }
            let length = try #require(resolved.normalizedGeometry.length)
            lengths.append(length)
            #expect(stop == length)
            #expect(try #require(values.initialNodeVoltages.values.first) == length / 1e-6)
            #expect(values.lowered.evaluationProvenance.seed == seed)
            #expect(values.lowered.evaluationProvenance.randomDraws == 2)
        }
        #expect(lengths[0] != lengths[1])
    }

    @Test func monteCarloUICIsExplicitlyRejectedBeforeLoad() async throws {
        var session = try Session(policy: .developerV1())
        do {
            try await session.loadNetlist(source: """
            Unsupported Monte Carlo UIC
            R1 out 0 1k
            C1 out 0 1n
            .ic V(out)=2
            .mc 2 tran 1n 10n uic
            .end
            """, fileName: nil)
            Issue.record("Unsupported Monte Carlo UIC was silently accepted")
        } catch let error as ParserDiagnostic {
            #expect(error.description.contains("Unsupported Monte Carlo option"))
            #expect(CoreSpiceCLIFailure(error: error).code == "deck.parse")
            #expect(!session.isLoaded)
            #expect(session.lastWaveform == nil)
        }
    }

    @Test func unusedAnalysisIsNotEvaluatedAndFailedInvocationClearsSuccess() async throws {
        var session = try Session(policy: .developerV1())
        try await session.loadNetlist(source: """
        Selected scalar authority
        V1 out 0 1
        R1 out 0 1k
        .op
        .ac dec 1 {missing_frequency} 1meg
        .end
        """, fileName: nil)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        _ = try await session.runParsed(session.requiredDefaultRunnableAnalysis())
        #expect(try #require(session.phaseCollector).isComplete)
        let ac = try #require(session.parsedNetlist?.analyses.last)
        do {
            _ = try await session.runParsed(ac)
            Issue.record("An unresolved selected field produced successful output")
        } catch {
            #expect(CoreSpiceCLIFailure(error: error).code == "mos.resolution")
            #expect(session.lastWaveform == nil)
            #expect(!((session.phaseCollector?.isComplete) ?? true))
        }
    }

    @Test func declaredCeilingsAreRefusedRatherThanSilentlyClamped() async throws {
        var session = try Session(policy: .developerV1())
        try await session.loadNetlist(source: """
        Preserve declared numerical ceiling
        V1 out 0 1
        R1 out 0 1k
        .options tranmaxaccepted=250000 tranmaxattempts=1000000 tranmaxiterations=5000000 tranmaxscalars=20000000 tranmaxdimension=2048 tranmaxwork=1e15 tranmaxbreakpoints=250000
        .tran 1n 10n
        .end
        """, fileName: nil)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        #expect(session.analysisOptions.executionLimits?.maximumSavedScalars == 20_000_000)
        do {
            _ = try await session.runParsed(session.requiredDefaultRunnableAnalysis())
            Issue.record("Oversized declared policy bypassed native admission")
        } catch {
            #expect(CoreSpiceCLIFailure(error: error).code == "preparation.capacity")
            #expect(session.analysisOptions.executionLimits?.maximumSavedScalars == 20_000_000)
            #expect(session.lastWaveform == nil)
            #expect(!((session.phaseCollector?.isComplete) ?? true))
        }
    }

    @Test func explicitProfileAndSeedAreValidatedByBatchArguments() throws {
        let options = try CoreSpiceBatchOptions(arguments: ["-b", "deck.cir", "--mos-profile", "coreStrictV1", "--seed", "42"])
        #expect(options.profile == .coreStrictV1)
        #expect(options.randomSeed == 42)
        #expect(throws: CLIError.self) {
            _ = try CoreSpiceBatchOptions(arguments: ["-b", "deck.cir", "--mos-profile", "unknown"])
        }
        #expect(throws: CLIError.self) {
            _ = try CoreSpiceBatchOptions(arguments: ["-b", "deck.cir", "--mos-profile", "coreStrictV1", "--mos-profile", "pinnedNgspiceNormalV1"])
        }
    }
}
