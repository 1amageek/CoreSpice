import CoreSpiceDevices
import CoreSpiceEvent
import Testing
@testable import CoreSpiceAnalysis

@Suite("Validated transient conditional scalar barrier", .timeLimit(.minutes(1)))
struct ValidatedTransientScalarBarrierTests {
    private func budget(work: Int = 10_000) throws -> TransientExecutionBudget {
        try TransientExecutionBudget(limits: .init(maximumAcceptedSteps: 1,
            maximumSolveAttempts: 1, maximumNewtonIterations: 1, maximumSavedScalars: 2,
            maximumMatrixDimension: 1, maximumWorkUnits: work, maximumBreakpoints: 1),
            dimension: 1, nonZeroCount: 1, deviceCount: 0)
    }

    @Test func decreasingRationalBarrierCoversTheWholeSlab() throws {
        // R=2-t/4 and G=R-5/4 have exact endpoint minima 7/4 and 1/2.
        let facts = try ValidatedScalarBarrier.check(initialRadius: 2, slope: -0.25,
            duration: 1, contractionLowerBound: 1, forcingUpperBound: 1,
            budget: budget(), cancellation: CancellationToken())
        #expect(facts.endpointRadiusUpperBound >= 1.75)
        #expect(facts.endpointRadiusUpperBound < 1.75.nextUp.nextUp.nextUp)
        #expect(facts.maximumRadiusUpperBound == 2)
        #expect(facts.initialRadius == 2 && facts.slope == -0.25 && facts.duration == 1)
    }

    @Test func increasingBarrierRetainsTheOutwardEndpointForTheNextSlab() throws {
        let owner = try budget()
        let first = try ValidatedScalarBarrier.check(initialRadius: 0.5, slope: 1,
            duration: 2, contractionLowerBound: 2, forcingUpperBound: 1,
            budget: owner, cancellation: CancellationToken())
        #expect(first.endpointRadiusUpperBound >= 2.5)
        #expect(first.maximumRadiusUpperBound == first.endpointRadiusUpperBound)
        let second = try ValidatedScalarBarrier.check(initialRadius: first.endpointRadiusUpperBound,
            slope: 0, duration: 1, contractionLowerBound: 2, forcingUpperBound: 1,
            budget: owner, cancellation: CancellationToken())
        #expect(second.initialRadius >= first.endpointRadiusUpperBound)
    }

    @Test func finalEndpointAndReversedInequalityCounterexamplesRefuse() throws {
        // At t=0 G=1/4 is positive, but G(1)=-1/2: checking only entry is unsound.
        #expect(throws: ValidatedScalarBarrierFailure.proposalNotCertified) {
            try ValidatedScalarBarrier.check(initialRadius: 2, slope: -0.75,
                duration: 1, contractionLowerBound: 1, forcingUpperBound: 1,
                budget: budget(), cancellation: CancellationToken())
        }
        // R=0 satisfies the error's upper inequality but not the barrier's lower inequality.
        #expect(throws: ValidatedScalarBarrierFailure.proposalNotCertified) {
            try ValidatedScalarBarrier.check(initialRadius: 0, slope: 0,
                duration: 1, contractionLowerBound: 1, forcingUpperBound: 1,
                budget: budget(), cancellation: CancellationToken())
        }
    }

    @Test func invalidGeometryAndNegativeEndpointRefuse() throws {
        for (radius, slope, duration, alpha, eta) in [
            (-1.0, 1.0, 1.0, 1.0, 1.0), (1, 1, 0, 1, 1),
            (1, 1, 1, 0, 1), (1, 1, 1, 1, -1), (1, .infinity, 1, 1, 1)
        ] {
            #expect(throws: ValidatedScalarBarrierFailure.invalidCoefficients) {
                try ValidatedScalarBarrier.check(initialRadius: radius, slope: slope,
                    duration: duration, contractionLowerBound: alpha, forcingUpperBound: eta,
                    budget: budget(), cancellation: CancellationToken())
            }
        }
        #expect(throws: ValidatedScalarBarrierFailure.proposalNotCertified) {
            try ValidatedScalarBarrier.check(initialRadius: 1, slope: -2,
                duration: 1, contractionLowerBound: 10, forcingUpperBound: 0,
                budget: budget(), cancellation: CancellationToken())
        }
    }

    @Test func arithmeticOverflowPropagatesInsteadOfPublishingPartialFacts() throws {
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try ValidatedScalarBarrier.check(initialRadius: 1, slope: .greatestFiniteMagnitude,
                duration: 2, contractionLowerBound: 1, forcingUpperBound: 0,
                budget: budget(), cancellation: CancellationToken())
        }
    }

    @Test func requestBudgetIsCumulativeAndCancellationPublishesNoFacts() throws {
        let owner = try budget(work: ValidatedScalarBarrier.workUnits)
        _ = try ValidatedScalarBarrier.check(initialRadius: 2, slope: 0, duration: 1,
            contractionLowerBound: 1, forcingUpperBound: 1, budget: owner,
            cancellation: CancellationToken())
        #expect(throws: TransientExecutionError.limitExceeded(resource: "workUnits",
            limit: ValidatedScalarBarrier.workUnits, requested: 2 * ValidatedScalarBarrier.workUnits)) {
            try ValidatedScalarBarrier.check(initialRadius: 2, slope: 0, duration: 1,
                contractionLowerBound: 1, forcingUpperBound: 1, budget: owner,
                cancellation: CancellationToken())
        }
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try ValidatedScalarBarrier.check(initialRadius: 2, slope: 0, duration: 1,
                contractionLowerBound: 1, forcingUpperBound: 1, budget: budget(),
                cancellation: cancellation)
            Issue.record("Cancelled scalar check published facts")
        } catch AnalysisError.cancelled {}
    }
}
