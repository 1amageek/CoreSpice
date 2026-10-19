import Testing
@testable import CoreSpiceAnalysis

@Suite("Invocation numerical resources", .timeLimit(.minutes(1)))
struct AnalysisExecutionResourcesTests {
    private func limits(work: Int = 100, attempts: Int = 10, iterations: Int = 10) -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 1, maximumSolveAttempts: attempts,
            maximumNewtonIterations: iterations, maximumSavedScalars: 2,
            maximumMatrixDimension: 8, maximumWorkUnits: work, maximumBreakpoints: 1)
    }

    @Test func secondCaseCannotOvershootInvocationWork() throws {
        let resources = try AnalysisExecutionResources(limits: limits())
        let first = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        let second = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        try first.chargeWork(60)
        #expect(throws: TransientExecutionError.limitExceeded(resource: "invocation.workUnits", limit: 100, requested: 110)) {
            try second.chargeWork(50)
        }
        #expect(first.statistics.workUnits == 60)
        #expect(second.statistics.workUnits == 0)
        #expect(resources.usage.workUnits == 60)
        try second.chargeWork(40)
        #expect(second.statistics.workUnits == 40)
        #expect(resources.usage.workUnits == 100)
    }

    @Test func caseStatisticsAndOutputCeilingsRemainIndependent() throws {
        let resources = try AnalysisExecutionResources(limits: limits(attempts: 2, iterations: 2))
        let first = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        let second = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        for budget in [first, second] {
            try budget.beginSolve()
            try budget.beginIteration()
            try budget.admitSavedPoint(accepted: true)
            #expect(budget.statistics.solveAttempts == 1)
            #expect(budget.statistics.newtonIterations == 1)
            #expect(budget.statistics.savedScalars == 2)
            #expect(budget.statistics.acceptedSteps == 1)
        }
        #expect(resources.usage.solveAttempts == 2)
        #expect(resources.usage.newtonIterations == 2)
        let third = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        #expect(throws: TransientExecutionError.limitExceeded(resource: "invocation.solveAttempts", limit: 2, requested: 3)) {
            try third.beginSolve()
        }
        #expect(third.statistics.solveAttempts == 0)
        #expect(throws: TransientExecutionError.limitExceeded(resource: "invocation.newtonIterations", limit: 2, requested: 3)) {
            try third.beginIteration()
        }
        #expect(third.statistics.newtonIterations == 0)
        #expect(resources.usage.workUnits == 24)
    }

    @Test func reboundKeepsCaseAndInvocationCounters() throws {
        let resources = try AnalysisExecutionResources(limits: limits())
        let original = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        try original.beginIteration()
        let fresh = try original.rebound(dimension: 4, nonZeroCount: 8, deviceCount: 3)
        try fresh.beginIteration()
        #expect(original.statistics.workUnits == 66)
        #expect(fresh.statistics.workUnits == 66)
        #expect(resources.usage.workUnits == 66)
        #expect(resources.usage.maximumMatrixDimension == 4)
        let nextCase = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        #expect(nextCase.statistics.workUnits == 0)
        #expect(throws: TransientExecutionError.self) { try nextCase.chargeWork(35) }
        #expect(nextCase.statistics.workUnits == 0)
        #expect(resources.usage.workUnits == 66)
    }

    @Test func localRefusalDoesNotChargeInvocation() throws {
        let resources = try AnalysisExecutionResources(limits: limits())
        let budget = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
        try budget.admitSavedScalars(2)
        #expect(throws: TransientExecutionError.self) { try budget.admitSavedScalars(1) }
        #expect(resources.usage.workUnits == 0)
        #expect(resources.usage.solveAttempts == 0)
        #expect(throws: TransientExecutionError.self) {
            _ = try resources.budget(dimension: 9, nonZeroCount: 1, deviceCount: 1)
        }
        #expect(resources.usage.maximumMatrixDimension == 0)
    }

    @Test func concurrentCasesShareOneAdmissionBoundary() async throws {
        let resources = try AnalysisExecutionResources(limits: limits(attempts: 5))
        let admitted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let budget = try resources.budget(dimension: 1, nonZeroCount: 1, deviceCount: 1)
                    do {
                        try budget.beginSolve()
                        return true
                    } catch TransientExecutionError.limitExceeded(let resource, _, _) where resource == "invocation.solveAttempts" {
                        #expect(budget.statistics.solveAttempts == 0)
                        return false
                    }
                }
            }
            var count = 0
            for try await success in group where success { count += 1 }
            return count
        }
        #expect(admitted == 5)
        #expect(resources.usage.solveAttempts == 5)
    }
}
