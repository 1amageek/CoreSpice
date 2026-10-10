@testable import CoreSpice
import CoreSpiceIO
import Testing
import Synchronization

extension PreparedNativeExecutionTests {
    private func budgetedCircuit(_ input: PreparedSPICESimulation, limits: TransientExecutionLimits,
                                 allocation: UInt64 = 32 * 1024 * 1024,
                                 resources: SourceBoundaryTestResources = .init()) throws -> PreparedNativeCircuit {
        try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(),
            limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: allocation),
            numericalLimits: limits, resources: resources)
    }
    private func operationLimits(newton: Int = 50_000, solves: Int = 10_000,
                                 saved: Int = 50_000) -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 5000, maximumSolveAttempts: solves,
            maximumNewtonIterations: newton, maximumSavedScalars: saved,
            maximumMatrixDimension: 32, maximumWorkUnits: 100_000_000, maximumBreakpoints: 1000)
    }

    @Test func concreteOperationsEnforceEmbeddedNewtonBudget() async throws {
        let input = try await self.input("embedded budget\nV1 out 0 1 AC 1\nR1 out 0 1k\n.op\n.end\n")
        for operation in ["ac", "noise", "tf", "pz", "sens", "sens-ac"] {
            let resources = SourceBoundaryTestResources()
            let baseline = resources.used(.liveOwnedBytes)
            do {
                let owner = try budgetedCircuit(input, limits: operationLimits(newton: 1), resources: resources)
                let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
                do {
                    switch operation {
                    case "ac": _ = try await ACAnalysis(sweep: .single(1000)).run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                    case "noise": _ = try await NoiseAnalysis(outputNode: out, sweep: .single(1000)).run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                    case "tf": _ = try await TransferFunctionAnalysis(outputNode: out, inputSourceName: "v1").run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                    case "pz": _ = try await PoleZeroAnalysis(outputNode: out, inputSourceName: "v1").run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                    case "sens": _ = try await SensitivityAnalysis(outputNode: out).run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                    case "sens-ac": _ = try await ACSensitivityAnalysis(outputPositiveNode: out, sweep: .single(1000)).run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                    default: throw AnalysisError.invalidConfiguration("Unknown budget test operation")
                    }
                    Issue.record("\(operation) published completed facts after ignoring the embedded Newton limit")
                } catch SPICENativeExecutionError.numerical(let cause) {
                    guard case TransientExecutionError.limitExceeded(let resource, let limit, let requested) = cause else { throw cause }
                    #expect(resource == "newtonIterations" && limit == 1 && requested == 2)
                }
            }
            #expect(resources.used(.liveOwnedBytes) == baseline)
        }
    }

    @Test func sensitivityPerturbationsShareSolveBudgetAcrossBaseline() async throws {
        let input = try await self.input("shared budget\nV1 out 0 1 AC 1\nR1 out 0 1k\n.op\n.end\n")
        let owner = try budgetedCircuit(input, limits: operationLimits(solves: 1))
        let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
        do {
            _ = try await SensitivityAnalysis(outputNode: out).run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("Sensitivity reset the solve budget before its perturbation")
        } catch SPICENativeExecutionError.numerical(let cause) {
            guard case TransientExecutionError.limitExceeded(let resource, let limit, let requested) = cause else { throw cause }
            #expect(resource == "solveAttempts" && limit == 1 && requested == 2)
        }
    }

    @Test func fourierRetainedHarmonicsMustFitAlongsideTransientStorage() async throws {
        let input = try await self.input("Fourier capacity\nV1 out 0 1\nR1 out 0 1k\n.tran 10u 100u\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else { Issue.record("Missing transient"); return }
        let limits = operationLimits(saved: 10_000)
        config.executionLimits = limits
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        let allocation: UInt64 = 350_000
        #expect(UInt64(MemoryLayout<FourierResult.HarmonicComponent>.stride * 10_000) > allocation)
        do {
            let owner = try budgetedCircuit(input, limits: limits, allocation: allocation, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            do {
                _ = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 9999,
                    outputNodes: [out], transientConfig: config).run(circuit: owner,
                        solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("Fourier published harmonics larger than its complete admitted native capacity")
            } catch SPICENativeExecutionError.resource {}
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }

    @Test func fourierAdmittedCapacityRetainsResultsAndChargesPostprocessing() async throws {
        let input = try await self.input("Fourier bounded success\nV1 out 0 1\nR1 out 0 1k\n.tran 10u 100u\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else { Issue.record("Missing transient"); return }
        var limits = operationLimits(saved: 10_000)
        config.executionLimits = limits
        let resources = SourceBoundaryTestResources()
        let liveBaseline = resources.used(.liveOwnedBytes)
        let temporaryBaseline = resources.used(.temporaryBytes)
        var transientWork = 0
        do {
            let owner = try budgetedCircuit(input, limits: limits, allocation: 500_000, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let run = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 999,
                outputNodes: [out], transientConfig: config).run(circuit: owner,
                    solver: SparseLUSolver(), observer: nil, cancellation: .init())
            let components = try #require(run.result.harmonics.values.first)
            #expect(components.count == 1000)
            #expect(run.phases.count == 1)
            let transientStatistics = try #require(run.result.transientResult.executionStatistics)
            let statistics = try #require(run.statistics)
            transientWork = transientStatistics.workUnits
            #expect(statistics.workUnits > transientWork)
            #expect(statistics.savedScalars == transientStatistics.savedScalars + 5001)
            #expect(resources.used(.liveOwnedBytes) >= liveBaseline + UInt64(MemoryLayout<FourierResult.HarmonicComponent>.stride * components.count))
            #expect(resources.used(.temporaryBytes) == temporaryBaseline)
            withExtendedLifetime(run) {}
        }
        #expect(resources.used(.liveOwnedBytes) == liveBaseline)
        #expect(resources.used(.temporaryBytes) == temporaryBaseline)

        // The exact transient work ceiling permits the physical trace and refuses the
        // subsequent harmonic computation through the same budget, without facts.
        limits.maximumWorkUnits = transientWork
        config.executionLimits = limits
        do {
            let owner = try budgetedCircuit(input, limits: limits, allocation: 500_000, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            do {
                _ = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 999,
                    outputNodes: [out], transientConfig: config).run(circuit: owner,
                        solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("Fourier ignored work after the completed transient trace")
            } catch SPICENativeExecutionError.numerical(let cause) {
                guard case TransientExecutionError.limitExceeded(let resource, let limit, let requested) = cause else { throw cause }
                #expect(resource == "workUnits" && limit == transientWork && requested > limit)
            }
        }
        #expect(resources.used(.liveOwnedBytes) == liveBaseline)
        #expect(resources.used(.temporaryBytes) == temporaryBaseline)
    }


    @Test func extractedFourierResultRetainsItsAdmittedHarmonicStorage() async throws {
        let input = try await self.input("Fourier retained result\nV1 out 0 1\nR1 out 0 1k\n.tran 10u 100u\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else { Issue.record("Missing transient"); return }
        let limits = operationLimits(saved: 10_000)
        config.executionLimits = limits
        let resources = SourceBoundaryTestResources()
        let liveBaseline = resources.used(.liveOwnedBytes)
        let temporaryBaseline = resources.used(.temporaryBytes)
        var retained: FourierResult?
        do {
            let owner = try budgetedCircuit(input, limits: limits, allocation: 500_000, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let run = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 999,
                outputNodes: [out], transientConfig: config).run(circuit: owner,
                    solver: SparseLUSolver(), observer: nil, cancellation: .init())
            retained = run.result
        }
        let componentCount = try #require(retained?.harmonics.values.first?.count)
        #expect(componentCount == 1000)
        #expect(resources.used(.liveOwnedBytes) >= liveBaseline + UInt64(MemoryLayout<FourierResult.HarmonicComponent>.stride * componentCount))
        #expect(resources.used(.temporaryBytes) == temporaryBaseline)
        withExtendedLifetime(retained) {}
        retained = nil
        #expect(resources.used(.liveOwnedBytes) == liveBaseline)
        #expect(resources.used(.temporaryBytes) == temporaryBaseline)
    }


    @Test func extractedDCAndTransientResultsRetainTheirAdmission() async throws {
        let input = try await self.input("Electrical retained result\nV1 out 0 1\nR1 out 0 1k\n.tran 10u 100u\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else { Issue.record("Missing transient"); return }
        let limits = operationLimits(saved: 10_000)
        config.executionLimits = limits
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        var retainedDC: DCResult?
        do {
            let owner = try budgetedCircuit(input, limits: limits, allocation: 500_000, resources: resources)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            retainedDC = run.result
        }
        let variableCount = try #require(retainedDC?.variables.count)
        #expect(resources.used(.liveOwnedBytes) >= baseline + UInt64(variableCount * MemoryLayout<Double>.stride))
        withExtendedLifetime(retainedDC) {}
        retainedDC = nil
        #expect(resources.used(.liveOwnedBytes) == baseline)

        var retainedTransient: TransientResult?
        do {
            let owner = try budgetedCircuit(input, limits: limits, allocation: 500_000, resources: resources)
            let run = try await TransientAnalysis(config: config).run(circuit: owner,
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            retainedTransient = run.result
        }
        let pointCount = try #require(retainedTransient?.timePoints.count)
        #expect(pointCount > 1)
        #expect(resources.used(.liveOwnedBytes) >= baseline + UInt64(pointCount * (variableCount + 1) * MemoryLayout<Double>.stride))
        withExtendedLifetime(retainedTransient) {}
        retainedTransient = nil
        #expect(resources.used(.liveOwnedBytes) == baseline)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    private final class RetainedSweepPoint: Sendable {
        private let point = Mutex<DCResult?>(nil)
        func retain(_ result: DCResult) { point.withLock { $0 = result } }
        func release() { point.withLock { $0 = nil } }
        var variableCount: Int? { point.withLock { $0?.variables.count } }
    }

    @Test func retainedSweepCallbackPointKeepsAdmissionAfterFailure() async throws {
        let input = try await self.input("Sweep retained point\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        let baseline = resources.used(.liveOwnedBytes)
        let retained = RetainedSweepPoint()
        do {
            let owner = try budgetedCircuit(input, limits: operationLimits(saved: 10_000),
                allocation: 500_000, resources: resources)
            do {
                _ = try await DCAnalysis().runSweep(circuit: owner, source: "v1", values: [0, 1],
                    solver: SparseLUSolver(), observer: nil, cancellation: .init()) { _, _, _, result in
                        retained.retain(result)
                        throw SourceBoundaryTestError.workLimit
                    }
                Issue.record("Throwing sweep callback published the whole result")
            } catch SPICENativeExecutionError.numerical(let cause) {
                #expect(cause as? SourceBoundaryTestError == .workLimit)
            }
        }
        let variableCount = try #require(retained.variableCount)
        #expect(resources.used(.liveOwnedBytes) >= baseline + UInt64(variableCount * MemoryLayout<Double>.stride))
        retained.release()
        #expect(resources.used(.liveOwnedBytes) == baseline)
        #expect(resources.used(.temporaryBytes) == 0)
    }

}
