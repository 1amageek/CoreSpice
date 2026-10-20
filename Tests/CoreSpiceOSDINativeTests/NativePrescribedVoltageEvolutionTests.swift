import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceParsedIR
import OSDIContracts
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Matched native chart evolution", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageEvolutionTests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0
            var temporary: UInt64 = 0
            var units: UInt64 = 0
            var peak: UInt64 = 0
            var refuseStorage = false
            var refuseWork = false
            var cancellation: CancellationToken?
            var cancelAt: UInt64 = 0
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var units: UInt64 { state.withLock { $0.units } }
        var peak: UInt64 { state.withLock { $0.peak } }
        func arm(storage: Bool = false, work: Bool = false) {
            state.withLock { $0.refuseStorage = storage; $0.refuseWork = work }
        }
        func beginMeasurement() { state.withLock { $0.peak = $0.live + $0.temporary } }
        func cancel(_ token: CancellationToken, after additionalUnits: UInt64) {
            state.withLock { $0.cancellation = token; $0.cancelAt = $0.units + additionalUnits }
        }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            let token = try state.withLock { value -> CancellationToken? in
                guard !value.refuseWork else { throw Refusal.work }
                value.units += units
                guard value.units >= value.cancelAt else { return nil }
                let token = value.cancellation; value.cancellation = nil
                return token
            }
            // Cancellation is external to the accounting lock, including reentrant token work.
            token?.cancel()
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try state.withLock { value in
                guard !value.refuseStorage else { throw Refusal.storage }
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
                value.peak = max(value.peak, value.live + value.temporary)
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { value in
                if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
            }}
        }
    }
    private func scalar(_ value: Double, radius: Double = 0) throws -> E {
        try .init(center: .init(high: value), radius: radius)
    }
    private func bounds(_ value: E) -> ClosedRange<Double> {
        let b = value.center.bounds
        return value.radius == 0 ? b.lower...b.upper : (b.lower - value.radius).nextDown...(b.upper + value.radius).nextUp
    }
    private func contains(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(bounds(value).contains(expected), sourceLocation: sourceLocation)
    }
    private func voltage(_ p: Node) -> Instance {
        .init(name: "V1", typeName: "vsource", nodes: [p, .ground], parameters: ["v": .real(0)], ownedBranches: [.init(id: 0)])
    }
    private func capacitor(_ name: String, _ p: Node, _ n: Node, _ value: Double) -> Instance {
        .init(name: name, typeName: "capacitor", nodes: [p, n], parameters: ["c": .real(value)])
    }
    private func prepare(_ instances: [Instance], nodes: [Node], resources: Resources) throws -> PreparedNativeCircuit {
        let dimension = nodes.count
        return try NativeCircuitPreparer().prepareNativeConstitutive(
            ir: .init(nodes: nodes, branches: [.init(id: 0)], instances: instances, branchNames: [.init(id: 0): "V1"]),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15),
            limits: .init(maximumDeviceCount: instances.count + 1, maximumMatrixDimension: dimension,
                maximumAllocationBytes: 268_435_456),
            numericalLimits: .init(maximumAcceptedSteps: 10, maximumSolveAttempts: 10, maximumNewtonIterations: 10,
                maximumSavedScalars: dimension * 2, maximumMatrixDimension: dimension,
                maximumWorkUnits: 1_000_000, maximumBreakpoints: 10),
            resources: resources, cancellation: .init())
    }
    private func valueLimits() -> NativePrescribedVoltageLimits {
        .init(maximumNativeTerms: 16_384, maximumRetainedBytes: 4_194_304, maximumWorkspaceBytes: 4_194_304,
            precisionBits: 192, reductionLimits: .init(maximumAxes: 16_384, maximumSources: 8,
                maximumWorkspaceBytes: 4_194_304, maximumResultBytes: 4_194_304))
    }
    private func chartLimits() -> NativePrescribedVoltageChartLimits {
        .init(maximumTriplets: 16_384, maximumRetainedBytes: 4_194_304, maximumWorkspaceBytes: 4_194_304,
            precisionBits: 192, values: valueLimits(),
            exact: .init(maximumRows: 1024, maximumColumns: 1024, maximumIntegerBits: 4096,
                maximumWorkspaceBytes: 4_194_304, maximumResultBytes: 4_194_304),
            root: .init(maximumDimension: 1024, maximumJacobianNonzeros: 16_384, maximumPreconditionerNonzeros: 16_384,
                maximumWorkspaceBytes: 4_194_304, maximumResultBytes: 4_194_304))
    }
    private func evolutionLimits(retained: Int = 524_288, workspace: Int = 524_288) -> NativePrescribedVoltageEvolutionLimits {
        .init(maximumRetainedBytes: retained, maximumWorkspaceBytes: workspace)
    }
    private func source() -> NativePrescribedVoltageSource {
        .init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: -3, timeScale: 2,
            normalized: 0.5...0.5, leftSlope: 1...1, rightSlope: 2...2)
    }
    private func domain(_ lower: [Double], _ upper: [Double]) throws -> NativeGlobalChargeDomain {
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return try .init(lower: lower.map { try .init(high: $0) }, upper: upper.map { try .init(high: $0) },
            lowerContext: context, upperContext: context)
    }
    private func fixture(resources: Resources) throws -> PreparedNativeCircuit {
        let p = Node(id: 1), d = Node(id: 2), x = Node(id: 3)
        return try prepare([voltage(p), capacitor("Cd", d, p, 2),
            .init(name: "Rd", typeName: "resistor", nodes: [d, .ground], parameters: ["r": .real(4)]),
            .init(name: "Rx", typeName: "resistor", nodes: [x, p], parameters: ["r": .real(4)]),
            capacitor("Cinput", p, .ground, 3)], nodes: [.ground, p, d, x], resources: resources)
    }
    private func chart(_ owner: borrowing PreparedNativeCircuit, current: ClosedRange<Double> = -10...0) async throws -> NativePrescribedVoltageChart {
        let v = try await owner.enclosePrescribedVoltageValues(
            originalDomain: domain([0.999, 0.98, 0.98, current.lowerBound], [1.001, 1.02, 1.02, current.upperBound]),
            sources: [source()], reducedCoordinates: [scalar(1, radius: 0.01), scalar(1, radius: 0.01)],
            capture: nil, limits: valueLimits(), cancellation: .init())
        return try await owner.certifyPrescribedVoltageChart(values: v, algebraicRows: [1], chargeParameters: [scalar(0)],
            center: [.init(high: 1), .init(high: 1)],
            inverse: .init(dimension: 2, rowPointers: [0, 1, 2], columnIndices: [0, 1]), inverseValues: [0.5, 4],
            capture: nil, range: nil, limits: chartLimits(), cancellation: .init())
    }
    private func evolve(_ owner: borrowing PreparedNativeCircuit, _ chart: NativePrescribedVoltageChart,
        limits: NativePrescribedVoltageEvolutionLimits? = nil, cancellation: CancellationToken = .init()) throws -> NativePrescribedVoltageEvolution {
        try owner.reconstructPrescribedVoltageChart(chart: chart, limits: limits ?? evolutionLimits(), cancellation: cancellation)
    }

    @Test func chargeAndAlgebraicForcingKeepBothInputTermsAndFullSourceRows() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources), actual = try await chart(owner)
            let result = try evolve(owner, actual)
            #expect(result.dimension == 4 && result.reducedCoordinateCount == 2 && result.chargeCoordinateCount == 1)
            contains(try result.chargeRate(at: 0), -0.25)
            #expect(!bounds(try result.chargeRate(at: 0)).contains(0))
            for (side, rateD, rateX, current, inputCharge) in [
                (NativePrescribedVoltageReconstruction.Side.left, 0.875, 1.0, -3.25, 3.25),
                (.right, 1.875, 2.0, -6.25, 6.25)] {
                contains(try result.reducedRate(at: 0, side: side), rateD)
                contains(try result.reducedRate(at: 1, side: side), rateX)
                // Omitting CE gives -.125 for dDot; omitting GE gives zero for xDot.
                #expect(!bounds(try result.reducedRate(at: 0, side: side)).contains(-0.125))
                #expect(!bounds(try result.reducedRate(at: 1, side: side)).contains(0))
                contains(try result.fullChargeRate(at: 0, side: side), inputCharge)
                contains(try result.fullChargeRate(at: 1, side: side), -0.25)
                contains(try result.fullChargeRate(at: 2, side: side), 0)
                contains(try result.fullChargeRate(at: 3, side: side), 0)
                contains(try result.selectedCurrent(at: 0, side: side), current)
                #expect(!bounds(try result.selectedCurrent(at: 0, side: side)).contains(0))
                contains(try result.coordinate(at: 0, side: side), 1)
                contains(try result.coordinate(at: 1, side: side), 1)
                contains(try result.coordinate(at: 2, side: side), 1)
            }
            #expect(throws: NativePrescribedVoltageEvolutionFailure.invalidInput) { try result.chargeRate(at: 1) }
            #expect(throws: NativePrescribedVoltageEvolutionFailure.invalidInput) { try result.reducedRate(at: -1, side: .left) }
            #expect(throws: NativePrescribedVoltageEvolutionFailure.invalidInput) { try result.selectedCurrent(at: 1, side: .right) }
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func everySelectedCurrentMustFitItsOriginalSectionBeforePublication() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources)
            for (current, expected) in [(-10.0 ... -4.0, NativePrescribedVoltageReconstruction.Side.left),
                (-5.0 ... -1.0, .right)] {
                let actual = try await chart(owner, current: current)
                do { _ = try evolve(owner, actual); Issue.record("Evolution escaped the original selected-current section") }
                catch NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(let row, let side) {
                    #expect(row == 3 && side == expected)
                }
            }
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func matchedOwnerCapacityCancellationAndFinalCopyKeepTheOriginalAdmission() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources), other = try fixture(resources: .init())
            let actual = try await chart(owner), live = resources.live, temporary = resources.temporary
            do { _ = try evolve(other, actual); Issue.record("A foreign prepared owner accepted the chart") }
            catch NativePrescribedVoltageEvolutionFailure.wrongOwner {}
            for limits in [evolutionLimits(retained: 0), evolutionLimits(workspace: 0)] {
                do { _ = try evolve(owner, actual, limits: limits); Issue.record("Invalid capacities admitted") }
                catch NativePrescribedVoltageEvolutionFailure.invalidInput {}
            }
            for limits in [evolutionLimits(retained: 1), evolutionLimits(workspace: 1), evolutionLimits(retained: Int.max, workspace: 1)] {
                do { _ = try evolve(owner, actual, limits: limits); Issue.record("Evolution ignored its capacity") }
                catch NativePrescribedVoltageEvolutionFailure.capacityExceeded {}
                #expect(resources.live == live && resources.temporary == temporary)
            }
            resources.arm(work: true)
            do { _ = try evolve(owner, actual); Issue.record("Original work refusal was hidden") }
            catch Refusal.work {}
            resources.arm(storage: true)
            do { _ = try evolve(owner, actual); Issue.record("Original storage refusal was hidden") }
            catch Refusal.storage {}
            resources.arm()
            let preCancelled = CancellationToken(); preCancelled.cancel()
            do { _ = try evolve(owner, actual, cancellation: preCancelled); Issue.record("Precancelled evolution published") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            #expect(resources.live == live && resources.temporary == temporary)
            let before = resources.units
            do { _ = try evolve(owner, actual) }
            let completeWork = resources.units - before
            #expect(completeWork > 1 && resources.live == live && resources.temporary == temporary)
            let cancellation = CancellationToken(), interruptedBefore = resources.units
            resources.cancel(cancellation, after: completeWork / 2)
            do { _ = try evolve(owner, actual, cancellation: cancellation); Issue.record("Mid-operation cancellation published") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            #expect(resources.units > interruptedBefore && resources.units - interruptedBefore < completeWork)
            #expect(resources.live == live && resources.temporary == temporary)
            var retained: NativePrescribedVoltageEvolution? = try evolve(owner, actual)
            try owner.close()
            do {
                let copy = try #require(retained)
                retained = nil
                contains(try copy.selectedCurrent(at: 0, side: .right), -6.25)
                #expect(resources.live > live)
            }
            #expect(resources.live == live && resources.temporary == temporary)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func fiveHundredTwelveDiagonalAxesRetainLinearManagedStorageWithoutNewQueries() async throws {
        let count = 512, resources = Resources()
        do {
            let p = Node(id: 1), free = (0..<count).map { Node(id: $0 + 2) }
            var devices = [voltage(p), capacitor("Cinput", p, .ground, 3)]
            for i in free.indices { devices.append(capacitor("C" + String(i), free[i], .ground, 2)) }
            let owner = try prepare(devices, nodes: [.ground, p] + free, resources: resources)
            let n = owner.plan.topology.dimension
            var lower = [Double](repeating: -1, count: n), upper = [Double](repeating: 2, count: n)
            lower[n - 1] = -10; upper[n - 1] = 0
            let values = try await owner.enclosePrescribedVoltageValues(originalDomain: domain(lower, upper),
                sources: [source()], reducedCoordinates: [E](repeating: scalar(0.5, radius: 0.5), count: count),
                capture: nil, limits: valueLimits(), cancellation: .init())
            let actual = try await owner.certifyPrescribedVoltageChart(values: values, algebraicRows: [],
                chargeParameters: [E](repeating: scalar(1), count: count),
                center: [CompensatedValue](repeating: .init(high: 0.5), count: count),
                inverse: .init(dimension: count, rowPointers: Array(0...count), columnIndices: Array(0..<count)),
                inverseValues: [Double](repeating: 0.5, count: count), capture: nil, range: nil,
                limits: chartLimits(), cancellation: .init())
            #expect(actual.dimension == count && actual.normUpperBound < 1e-10)
            let baseline = resources.live + resources.temporary, before = resources.units
            resources.beginMeasurement()
            do {
                let result = try evolve(owner, actual)
                #expect(result.reducedCoordinateCount == count && result.chargeCoordinateCount == count)
                for row in 0..<count {
                    contains(try result.chargeRate(at: row), 0)
                    contains(try result.reducedRate(at: row, side: .left), 0)
                    contains(try result.reducedRate(at: row, side: .right), 0)
                }
                contains(try result.fullChargeRate(at: 0, side: .left), 3)
                contains(try result.fullChargeRate(at: 0, side: .right), 6)
                contains(try result.selectedCurrent(at: 0, side: .left), -3)
                contains(try result.selectedCurrent(at: 0, side: .right), -6)
                let managedPeak = resources.peak - baseline, work = resources.units - before
                #expect(managedPeak < 524_288 && work < 100_000)
                print("evolution sparse n=\(count) originalN=\(n) managedPeakDelta=\(managedPeak) work=\(work) retainedDelta=\(resources.live + resources.temporary - baseline)")
            }
            #expect(resources.live + resources.temporary == baseline)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
