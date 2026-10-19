import Testing
import Synchronization
@testable import CoreSpice

@Suite("Native compensated transient propagation", .timeLimit(.minutes(1)))
struct NativeCompensatedTransientTests {
    @Test(arguments: [false, true])
    func actualPreparedCapacitorPreservesSelectedLaneAndItsResultLease(precise: Bool) async throws {
        let resources = SourceBoundaryTestResources()
        var retained: TransientResult?
        do {
            var netlist = Netlist()
            let node = netlist.node("out")
            try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                parameters: ["c": .real(0x1p-37)])
            try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"],
                parameters: ["i": .real(-0x1p-39)])
            let limits = TransientExecutionLimits(maximumAcceptedSteps: 32, maximumSolveAttempts: 200,
                maximumNewtonIterations: 1000, maximumSavedScalars: 1000, maximumMatrixDimension: 4,
                maximumWorkUnits: 10_000_000, maximumBreakpoints: 8)
            let owner = try NativeCircuitPreparer().prepare(ir: netlist.build(), registry: .standard(),
                operatingConditions: .nominal,
                limits: .init(maximumDeviceCount: 8, maximumMatrixDimension: 4, maximumAllocationBytes: 1024 * 1024),
                numericalLimits: limits, resources: resources)
            let (record, devices) = owner.takeState()
            let contributors = try devices.map { device -> any TransientPhysicalResidualEnclosureContributing in
                try #require(device as? any TransientPhysicalResidualEnclosureContributing)
            }
            let enclosing = NativeTestEnclosingCircuit(contributors: contributors)
            let initial = SolutionState(variables: [0.5], variableMap: record.plan.topology.variableMap)
            let completion = NativeTestCompletion(sessions: devices.compactMap { $0 as? any TransientSessionDevice },
                initial: initial)
            let h = 0x1p-54
            let config = TransientConfig(stopTime: 4 * h, executionLimits: limits, maxTimeStep: h,
                initialTimeStep: h, minTimeStep: h / 16, preferredMethod: .trapezoidal,
                useInitialConditions: true, initialNodeVoltages: [node: 0.5], gminSteppingThreshold: .max)
            let policy = try DCEquationPolicy(rows: [.init(kind: .electricalPotential,
                variableAbsoluteTolerance: 1e-9, equationAbsoluteTolerance: 1e-12)])
            let run = try await TransientAnalysis(config: config,
                convergenceConfig: .init(reltol: 0x1p-52, maxIterations: 30, gmin: 0),
                equationPolicy: precise ? policy : nil, completionFinalizer: completion,
                physicalResidualEncloser: precise ? enclosing : nil)
                .run(circuit: PreparedNativeCircuit(record: record, devices: devices), solver: SparseLUSolver(),
                    observer: nil, cancellation: .init())
            #expect(run.phases.map(\.analysis) == ["tran"])
            #expect(run.phases.map(\.completedPointCount) == [run.result.timePoints.count])
            #expect(run.result.operatingPoint == nil)
            #expect(run.result.timePoints.last == config.stopTime)
            #expect(run.result.acceptedSteps.count == run.result.timePoints.count - 1)
            #expect(completion.completedCount == 1)
            if precise {
                let low = try #require(run.result.solutionLowTrace)
                #expect(low.rowMajorValues.contains { $0 != 0 })
                for point in run.result.timePoints.indices {
                    let value = try run.result.checkedCompensatedValue(variableIndex: 0, timeIndex: point)
                    #expect(value.high == 0.5)
                    #expect(abs(value.low - run.result.timePoints[point] * 0.25) <= 0x1p-95)
                }
                for (index, step) in run.result.acceptedSteps.enumerated() {
                    let exact = try CompensatedValue(high: run.result.timePoints[index + 1])
                        .subtracting(CompensatedValue(high: run.result.timePoints[index]))
                    #expect(try exact == CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent))
                }
            } else {
                #expect(run.result.solutionLowTrace == nil)
                #expect(run.result.solutionTrace.rowMajorValues.allSatisfy { $0 == 0.5 })
                #expect(run.result.acceptedSteps.allSatisfy { $0.timeStepLowComponent == 0 })
            }
            retained = run.result
        }
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.used(.liveOwnedBytes) > 0)
        withExtendedLifetime(retained) {}
        retained = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }
}

private struct NativeTestEnclosingCircuit: TransientPhysicalResidualEnclosing {
    let contributors: [any TransientPhysicalResidualEnclosureContributing]

    func accumulateResidualEnclosure(state: SolutionState, integration: IntegrationState,
                                    add: (Int, CompensatedValue, Double) -> Void) throws {
        for contributor in contributors {
            try contributor.accumulateTransientPhysicalResidualEnclosure(state: state, integration: integration, add: add)
        }
    }

    func validate(state: SolutionState, integration: IntegrationState) throws {
        var residual = try CompensatedEnclosure(center: .zero)
        var failure: (any Error)?
        try accumulateResidualEnclosure(state: state, integration: integration) { row, center, radius in
            guard failure == nil else { return }
            do {
                guard row == 0 else { throw NonlinearPhysicalResidualError.invalidRow(row: row, dimension: 1) }
                residual = try residual.adding(CompensatedEnclosure(center: center, radius: radius))
            } catch { failure = error }
        }
        if let failure { throw failure }
        guard residual.absoluteUpperBound <= 1e-12 else {
            throw NonlinearPhysicalResidualError.uncertifiedResidual(row: 0,
                upperBound: residual.absoluteUpperBound, tolerance: 1e-12)
        }
    }
}

private final class NativeTestCompletion: AnalysisCompletionFinalizing {
    let sessions: [any TransientSessionDevice]
    let initial: SolutionState
    private let count = Mutex(0)

    init(sessions: [any TransientSessionDevice], initial: SolutionState) {
        self.sessions = sessions; self.initial = initial
    }

    var completedCount: Int { count.withLock { $0 } }

    func finalizeCompletion() throws {
        for session in sessions {
            try session.beginTransientSession(initialState: initial)
            session.endTransientSession()
        }
        count.withLock { $0 += 1 }
    }
}
