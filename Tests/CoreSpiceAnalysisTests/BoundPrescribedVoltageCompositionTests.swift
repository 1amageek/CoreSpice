import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceEvent
@testable import CoreSpiceAnalysis
import Synchronization
import Testing

@Suite("Actual prescribed source and capacitor reconstruction", .timeLimit(.minutes(1)))
struct BoundPrescribedVoltageCompositionTests {
    private typealias E = CompensatedEnclosure
    private func scalar(_ value: Double) throws -> E { try E(center: CompensatedValue(high: value)) }
    private func contains(_ value: E, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let bounds = value.center.bounds
        let lo = value.radius == 0 ? bounds.lower : (bounds.lower - value.radius).nextDown
        let hi = value.radius == 0 ? bounds.upper : (bounds.upper + value.radius).nextUp
        #expect(lo <= expected && expected <= hi, sourceLocation: sourceLocation)
    }

    @Test func actualSourceAndActualCapacitorRetainBothOneSidedCurrentsAndAllOriginalRows() throws {
        let node = Node(id: 1), branch = Branch(id: 5)
        let axis: [MNAVariable: Int] = [.nodeVoltage(node): 0, .branchCurrent(branch): 1]
        let storage = Storage()
        for reversed in [false, true] {
            let positive = reversed ? Node.ground : node, negative = reversed ? node : Node.ground
            var context = BindingContext(variableMap: axis, matrixDimension: 2)
            let v = try #require(VoltageSourceDescriptor().bind(instance:
                Instance(name: "Vactual", typeName: "vsource", nodes: [positive, negative],
                    parameters: ["v": .real(0)], ownedBranches: [branch]), context: &context) as? BoundVoltageSource)
            let capacitor = try CapacitorDescriptor().bind(instance:
                Instance(name: "Cactual", typeName: "capacitor", nodes: [positive, negative],
                    parameters: ["c": .real(3)]), context: &context)
            let budget = try TransientExecutionBudget(limits: .init(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
                maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 4,
                maximumWorkUnits: 1_000_000, maximumBreakpoints: 10), dimension: 2, nonZeroCount: 4, deviceCount: 2)
            let cancellation = CancellationToken()
            func checkpoint() throws {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw AnalysisError.cancelled }
                try budget.chargeWork(1)
            }
            let source = try v.makePrescribedVoltageLaw(zeroVoltage: -0.25, oneVoltage: 1.75,
                timeOrigin: 2, timeScale: 0.5, variableMap: axis, checkpoint: checkpoint)
            let jet = try source.enclose(normalized: 0.5...0.5, leftSlope: 0.5...0.5,
                rightSlope: 2...2, over: -2 ... -2, checkpoint: checkpoint)
            let reduction = try PrescribedVoltageReduction(limits: .init(maximumAxes: 4, maximumSources: 1,
                maximumWorkspaceBytes: 1_000_000, maximumResultBytes: 1_000_000),
                budget: budget, storage: storage, cancellation: cancellation)
            let fact = source.sourceFact
            let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow],
                sources: [.init(positiveRow: fact.positiveRow, negativeRow: fact.negativeRow, branchRow: fact.branchRow)])
            let workspace = try reduction.makeWorkspace(plan: plan)
            let zero = try scalar(0)
            for (slope, expectedRate) in [(jet.leftSlope, 2.0), (jet.rightSlope, 8.0)] {
                var chargeRate = [zero, zero]
                let voltageRate = reversed ? try slope.negated() : slope
                let chargeLaw = try #require(capacitor as? any ContinuousEquationLinearLawProviding)
                try chargeLaw.visitContinuousEquationLinearLaw(checkpoint: checkpoint) { term in
                    try term.validateJoin(variableMap: axis, device: capacitor.instance.name)
                    #expect(term.plane == .charge && term.column == 0)
                    chargeRate[term.row] = try chargeRate[term.row].adding(
                        scalar(Double(bitPattern: term.coefficientBits)).multiplied(by: voltageRate))
                }
                let application = try reduction.apply(workspace: workspace, reducedCoordinates: [],
                    sourceValues: [jet.voltage], staticResidual: [zero, zero], stateChargeRate: [zero, zero],
                    prescribedChargeRate: chargeRate, explicitTimeChargeRate: [zero, zero])
                contains(try application.coordinate(at: 0), reversed ? -0.75 : 0.75)
                contains(try application.coordinate(at: 1), -3 * expectedRate)
                for row in 0..<2 { contains(try application.originalResidual(at: row), 0) }
                // Independently re-evaluate the actual source branch at the reconstructed point.
                let state = SolutionState(variables: [reversed ? -0.75 : 0.75, -3 * expectedRate], variableMap: axis)
                var original = chargeRate
                try source.accumulateResidualEnclosure(state: state, normalized: 0.5...0.5,
                    at: -2, checkpoint: checkpoint) { row, center, radius in
                        original[row] = try original[row].adding(E(center: center, radius: radius))
                    }
                for row in 0..<2 { contains(original[row], 0) }
                #expect(source.charge.center == .zero && source.charge.radius == 0)
            }
            #expect(budget.statistics.solveAttempts == 0 && budget.statistics.newtonIterations == 0)
        }
        #expect(storage.live == 0)
    }

    private final class Storage: AnalysisResultStorageAccounting, Sendable {
        private let state = Mutex<UInt64>(0)
        var live: UInt64 { state.withLock { $0 } }
        func reserveResultScalars(_ capacity: Int) throws { Issue.record("Unexpected waveform output allocation") }
        func reserveTemporaryBytes(_ bytes: UInt64) throws -> any Sendable {
            try state.withLock { value in
                let (next, overflow) = value.addingReportingOverflow(bytes)
                guard !overflow, next <= 1_000_000 else { throw Refusal.capacity }
                value = next
            }
            return Lease(owner: self, bytes: bytes)
        }
        private enum Refusal: Error { case capacity }
        private final class Lease: Sendable {
            let owner: Storage
            let bytes: UInt64
            init(owner: Storage, bytes: UInt64) { self.owner = owner; self.bytes = bytes }
            deinit { owner.state.withLock { $0 -= bytes } }
        }
    }
}
