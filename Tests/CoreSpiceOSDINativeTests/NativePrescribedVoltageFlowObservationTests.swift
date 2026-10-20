@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceParsedIR
import Foundation
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Same-flow electrical voltage observations", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageFlowObservationTests {
    private typealias E = CompensatedEnclosure
    private typealias Pair = NativePrescribedVoltageFlowVoltagePair
    private typealias Limits = NativePrescribedVoltageFlowObservationLimits
    private typealias Failure = NativePrescribedVoltageFlowObservationFailure
    private let base = NativePrescribedVoltageFlowTests()
    private func limits(count: Int = 16, retained: Int = 1_048_576, workspace: Int = 1_048_576) -> Limits {
        .init(maximumPairCount: count, maximumRetainedBytes: retained, maximumWorkspaceBytes: workspace)
    }
    private func narrowRequest(source: NativePrescribedVoltageFlowSource? = nil) throws -> NativePrescribedVoltageFlowRequest {
        let r = try base.request(source: source)
        return .init(originalLower: try [0.95, 0.35, 0.85, -10].map { try .init(high: $0) },
            originalUpper: try [1.05, 0.65, 1.15, 10].map { try .init(high: $0) }, startTime: r.startTime,
            duration: r.duration, sources: r.sources, algebraicRows: r.algebraicRows,
            dynamicInitialCoordinates: try [base.e(0.499, 0.501)],
            initial: try base.proposal([base.e(0.49, 0.51), base.e(0.99, 1.01)], initial: true),
            chargeBox: try [base.e(0.9, 1.15)],
            window: try base.proposal([base.e(0.4, 0.6), base.e(0.9, 1.1)], initial: false))
    }

    @Test func actualRCVoltageDerivativeIsNotChargeDerivativeAndRetainsItsExactFlow() async throws {
        let resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try base.fixture(resources: resources)
            do {
                let flow = try await base.flow(owner, narrowRequest())
                let pairs: [Pair] = [.init(positive: base.d, reference: .ground),
                    .init(positive: .ground, reference: base.d), .init(positive: base.d, reference: base.d),
                    .init(positive: .ground, reference: .ground), .init(positive: base.x, reference: base.p)]
                let observed = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                #expect(observed.flow === flow && observed.count == pairs.count)
                let d = try observed.observation(at: 0), reversed = try observed.observation(at: 1)
                base.contains(d.initialVoltage, 0.5)
                base.contains(d.windowVoltage, 1 - 0.5 * exp(-flow.duration.high / 4))
                base.contains(d.almostEverywhereRate, 0.125)
                #expect(d.almostEverywhereRate.absoluteUpperBound < 0.2)
                base.contains(try flow.chargeRateAlmostEverywhere(at: 0), 0.25)
                #expect(reversed.initialVoltage == (try d.initialVoltage.negated()))
                #expect(reversed.windowVoltage == (try d.windowVoltage.negated()))
                #expect(reversed.almostEverywhereRate == (try d.almostEverywhereRate.negated()))
                let zero = try E(center: .zero)
                for index in 2..<4 {
                    let row = try observed.observation(at: index)
                    #expect(row.initialVoltage == zero && row.windowVoltage == zero && row.almostEverywhereRate == zero)
                }
                base.contains(try observed.observation(at: 4).initialVoltage, 0)
                let reservations = resources.reservations, work = resources.work
                for _ in 0..<64 {
                    observed.withObservations { rows in
                        let count = rows.count, first = rows[0].pair
                        #expect(count == pairs.count)
                        #expect(first == pairs[0])
                    }
                }
                #expect(resources.reservations == reservations && resources.work == work)
                do { _ = try observed.observation(at: -1); Issue.record("Negative observation index admitted") }
                catch Failure.invalidInput {}
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test(arguments: [false, true])
    func physicalSIDerivativeUsesNonunitTimeScaleAndSignedRailsExactlyOnce(reversed: Bool) async throws {
        let owner = try base.fixture(isolated: true)
        do {
            let source = NativePrescribedVoltageFlowSource(deviceIndex: 0, zeroVoltage: reversed ? 2 : 0,
                oneVoltage: reversed ? 0 : 2, timeOrigin: -3, timeScale: 4,
                initialNormalized: 0.5...0.5, normalized: 0.4...0.6,
                normalizedDerivativePerSecond: 0.25...0.25)
            let flow = try await base.flow(owner, base.request(source: source))
            let pairs: [Pair] = [.init(positive: base.p, reference: .ground), .init(positive: base.x, reference: .ground)]
            let observed = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
            for index in 0..<2 {
                let row = try observed.observation(at: index)
                base.contains(row.initialVoltage, 1)
                base.contains(row.almostEverywhereRate, reversed ? -0.5 : 0.5)
                #expect(row.almostEverywhereRate.absoluteUpperBound < 0.51)
            }
        } catch { try owner.close(); throw error }
        try owner.close()
    }

    @Test func floatingSourceKeepsItsDynamicRootGaugeInsteadOfInventingGround() async throws {
        let resources = NativePrescribedVoltageFlowTests.Resources()
        let owner = try prepareFloating(resources: resources)
        do {
            let flow = try await base.flow(owner, floatingRequest())
            let pairs: [Pair] = [.init(positive: base.p, reference: .ground),
                .init(positive: base.d, reference: .ground), .init(positive: base.p, reference: base.d)]
            let observed = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
            let p = try observed.observation(at: 0), d = try observed.observation(at: 1), difference = try observed.observation(at: 2)
            base.contains(p.initialVoltage, 1.5); base.contains(d.initialVoltage, 0.5)
            #expect(p.initialVoltage.center.bounds.lower - p.initialVoltage.radius > 1)
            base.contains(p.almostEverywhereRate, -0.125); base.contains(d.almostEverywhereRate, -0.125)
            base.contains(difference.initialVoltage, 1); base.contains(difference.windowVoltage, 1)
            base.contains(difference.almostEverywhereRate, 0)
        } catch { try owner.close(); throw error }
        try owner.close()
    }

    @Test func actualRowNatureAndNamespacesRefuseThermalFlowAndUnrelatedNodes() throws {
        let control = AnalysisLinearSolverControl(budget: nil, cancellation: .init(), storage: nil)
        let reduction = try PrescribedVoltageReduction(limits: .init(maximumAxes: 3, maximumSources: 0,
            maximumWorkspaceBytes: 65_536, maximumResultBytes: 65_536), control: control)
        let plan = try reduction.prepare(axes: [.electricalPotential, .thermalPotential, .electricalFlow], sources: [])
        let electrical = Node(id: 8), thermal = Node(id: 9), flow = Node(id: 10)
        let map: [MNAVariable: Int] = [.nodeVoltage(electrical): 0, .nodeVoltage(thermal): 1,
            .nodeVoltage(flow): 2, .branchCurrent(.init(id: 77)): 2]
        #expect(try NativePrescribedVoltageFlowObservationAssembly.electricalRow(node: electrical, variableMap: map, plan: plan) == 0)
        #expect(try NativePrescribedVoltageFlowObservationAssembly.electricalRow(node: .ground, variableMap: map, plan: plan) == nil)
        for node in [thermal, flow] {
            do { _ = try NativePrescribedVoltageFlowObservationAssembly.electricalRow(node: node, variableMap: map, plan: plan); Issue.record("Nonelectrical row admitted") }
            catch Failure.nonElectricalNode(let actual) { #expect(actual == node) }
        }
        let unrelated = Node(id: 77)
        do { _ = try NativePrescribedVoltageFlowObservationAssembly.electricalRow(node: unrelated, variableMap: map, plan: plan); Issue.record("Branch ID treated as node ID") }
        catch Failure.unknownNode(let actual) { #expect(actual == unrelated) }
        for (pairs, axes) in [(Int.max, 1), (1, Int.max)] {
            do { _ = try NativePrescribedVoltageFlowObservationAssembly.storageBytes(pairCount: pairs, axisCount: axes); Issue.record("Overflowed observation layout") }
            catch Failure.capacityExceeded {}
        }
    }

    @Test func exactLocalCapsAndCumulativeWorkRefuseWithoutResetAndRefundTemporaryStorage() async throws {
        let resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try base.fixture(resources: resources)
            do {
                let flow = try await base.flow(owner, narrowRequest())
                let pairs: [Pair] = [.init(positive: base.d, reference: .ground)]
                let bytes = try NativePrescribedVoltageFlowObservationAssembly.storageBytes(pairCount: 1, axisCount: flow.dimension)
                let baseline = resources.live + resources.temporary
                for cap in [limits(retained: bytes.retained - 1), limits(workspace: bytes.workspace - 1)] {
                    do { _ = try flow.observeVoltages(pairs: pairs.span, limits: cap, cancellation: .init()); Issue.record("Local byte boundary ignored") }
                    catch Failure.capacityExceeded {}
                    #expect(resources.live + resources.temporary == baseline)
                }
                let exact = limits(retained: bytes.retained, workspace: bytes.workspace)
                let before = resources.work
                do { _ = try flow.observeVoltages(pairs: pairs.span, limits: exact, cancellation: .init()) }
                let cost = resources.work - before
                #expect(cost > 1 && resources.live + resources.temporary == baseline)
                try resources.charge(.retainedElements, units: 17)
                resources.arm(work: cost - 1)
                do { _ = try flow.observeVoltages(pairs: pairs.span, limits: exact, cancellation: .init()); Issue.record("Observation reset cumulative work") }
                catch Failure.operation(let cause) { guard case NativePrescribedVoltageFlowTests.Refusal.work = cause else { throw cause } }
                resources.arm(deny: true)
                do { _ = try flow.observeVoltages(pairs: pairs.span, limits: exact, cancellation: .init()); Issue.record("Original storage denial ignored") }
                catch Failure.operation(let cause) { guard case NativePrescribedVoltageFlowTests.Refusal.storage = cause else { throw cause } }
                resources.arm()
                #expect(resources.live + resources.temporary == baseline)
                let cancelled = CancellationToken(); cancelled.cancel()
                do { _ = try flow.observeVoltages(pairs: pairs.span, limits: exact, cancellation: cancelled); Issue.record("Cancelled observation published") }
                catch Failure.cancelled {}
                let empty: [Pair] = []
                do { _ = try flow.observeVoltages(pairs: empty.span, limits: exact, cancellation: .init()); Issue.record("Empty observation admitted") }
                catch Failure.invalidInput {}
                do { _ = try flow.observeVoltages(pairs: pairs.span, limits: exact, cancellation: .init()) }
                #expect(resources.live + resources.temporary == baseline)
            } catch { resources.arm(); try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func copiedObservationRetainsTheActualFlowAndOnlyFinalReleaseRefundsIt() async throws {
        let resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try base.fixture(resources: resources)
            let baseline = resources.live + resources.temporary
            var observations: NativePrescribedVoltageFlowVoltageObservations?
            do {
                let flow = try await base.flow(owner, narrowRequest())
                let pairs: [Pair] = [.init(positive: base.d, reference: .ground)]
                observations = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                #expect(observations?.flow === flow)
            }
            var copy = observations
            observations = nil; try owner.close()
            #expect(resources.live + resources.temporary > baseline)
            do {
                let retained = try #require(copy)
                base.contains(try retained.observation(at: 0).initialVoltage, 0.5)
                base.contains(try retained.flow.endpointCharge(at: 0), 2 - exp(-0.125 / 4))
            }
            copy = nil
            #expect(resources.live + resources.temporary == baseline)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test(arguments: [1, 2])
    func cancellationDuringOriginalStorageAdmissionCannotPublishAndLeavesFlowReusable(reservation: Int) async throws {
        let resources = CancelOnReserve(), preparationToken = CancellationToken()
        do {
            let owner = try prepareFloating(resources: resources, cancellation: preparationToken)
            do {
                let flow = try await base.flow(owner, floatingRequest())
                let baseline = resources.base.live + resources.base.temporary
                let pairs: [Pair] = [.init(positive: base.p, reference: .ground)]
                let token = CancellationToken()
                resources.arm(token, atReservation: reservation)
                do { _ = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: token); Issue.record("Admission-time cancellation published observations") }
                catch Failure.cancelled {}
                #expect(token.isCancelled && !preparationToken.isCancelled)
                let events = resources.events
                #expect(events.reservations == reservation)
                #expect(events.cancelledReservation == reservation)
                #expect(events.reservationsAfterCancellation == 0)
                #expect(events.workAfterCancellation == 0)
                #expect(resources.base.live + resources.base.temporary == baseline)
                resources.disarm()
                do {
                    let observed = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                    base.contains(try observed.observation(at: 0).initialVoltage, 1.5)
                }
                #expect(resources.base.live + resources.base.temporary == baseline)
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.base.live == 0 && resources.base.temporary == 0)
    }

    @Test(arguments: [false, true])
    func perCallCancellationInterruptsInnerWorkspaceAndBoundedWalk(duringWalk: Bool) async throws {
        let resources = CancelOnReserve(), preparationToken = CancellationToken()
        do {
            let owner = try prepareFloating(resources: resources, cancellation: preparationToken)
            do {
                let flow = try await base.flow(owner, floatingRequest())
                let baseline = resources.base.live + resources.base.temporary
                let pairs: [Pair] = [.init(positive: base.p, reference: .ground)]
                let operationToken = CancellationToken()
                if duringWalk { resources.arm(operationToken, atWork: 256) }
                else { resources.arm(operationToken, atReservation: 3) }
                do {
                    _ = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: operationToken)
                    Issue.record("Inner-primitive cancellation published observations")
                } catch Failure.cancelled {}
                let events = resources.events
                #expect(operationToken.isCancelled && !preparationToken.isCancelled)
                #expect(events.reservations == 3)
                #expect(events.reservationsAfterCancellation == 0)
                #expect(events.workAfterCancellation == 0)
                if duringWalk { #expect(events.cancelledWork == 256) }
                else { #expect(events.cancelledReservation == 3) }
                #expect(resources.base.live + resources.base.temporary == baseline)
                resources.disarm()
                do {
                    let observed = try flow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                    base.contains(try observed.observation(at: 0).initialVoltage, 1.5)
                }
                #expect(resources.base.live + resources.base.temporary == baseline)
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.base.live == 0 && resources.base.temporary == 0)
    }

    private final class CancelOnReserve: SPICESourceResourceAccounting {
        struct Events {
            var reservations = 0
            var reservationsAfterCancellation = 0
            var workAfterCancellation: UInt64 = 0
            var cancelledReservation: Int?
            var cancelledWork: UInt64?
        }
        private struct State {
            var token: CancellationToken?
            var atReservation: Int?
            var atWork: UInt64?
            var cancelled = false
            var events = Events()
        }
        let base = NativePrescribedVoltageFlowTests.Resources()
        private let state = Mutex(State())
        var events: Events { state.withLock { $0.events } }
        func arm(_ token: CancellationToken, atReservation: Int? = 1, atWork: UInt64? = nil) {
            state.withLock { $0 = State(token: token, atReservation: atWork == nil ? atReservation : nil, atWork: atWork) }
        }
        func disarm() { state.withLock { $0 = State() } }
        func checkCancellation() throws { try base.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try base.charge(kind, units: units)
            let cancelled = state.withLock { value -> CancellationToken? in
                if value.cancelled { value.events.workAfterCancellation += units }
                guard let token = value.token, value.atWork == units else { return nil }
                value.token = nil; value.cancelled = true; value.events.cancelledWork = units
                return token
            }
            cancelled?.cancel()
        }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try charge(.retainedElements, units: byteCount) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            let reservation = try base.reserveStorage(kind: kind, byteCount: byteCount)
            let cancelled = state.withLock { value -> CancellationToken? in
                value.events.reservations += 1
                if value.cancelled { value.events.reservationsAfterCancellation += 1 }
                guard let token = value.token, value.atReservation == value.events.reservations else { return nil }
                value.token = nil; value.cancelled = true; value.events.cancelledReservation = value.events.reservations
                return token
            }
            cancelled?.cancel()
            return reservation
        }
    }

    private func floatingRequest() throws -> NativePrescribedVoltageFlowRequest {
        let inverse = try SparseStructure(dimension: 2, rowPointers: [0, 1, 3], columnIndices: [0, 0, 1])
        let initial = NativePrescribedVoltageFlowRootProposal(coordinates: try [base.e(1.4, 1.6), base.e(1.3, 1.7)],
            center: try [.init(high: 1.5), .init(high: 1.5)], inverse: inverse, inverseValues: [1, 1, 4])
        let window = NativePrescribedVoltageFlowRootProposal(coordinates: try [base.e(0.5, 2.5), base.e(0.4, 2.6)],
            center: try [.init(high: 1.5), .init(high: 1.5)], inverse: inverse, inverseValues: [0.5, 0.5, 4])
        return NativePrescribedVoltageFlowRequest(originalLower: try [-4.0, -4, -4, -10].map { try .init(high: $0) },
            originalUpper: try [4.0, 4, 4, 10].map { try .init(high: $0) }, startTime: .zero,
            duration: try .init(high: 0.125), sources: [base.source()], algebraicRows: [1],
            dynamicInitialCoordinates: try [base.e(1.49, 1.51)], initial: initial,
            chargeBox: try [base.e(0, 2)], window: window)
    }

    private func prepareFloating(resources: any SPICESourceResourceAccounting, cancellation: CancellationToken = .init()) throws -> PreparedNativeCircuit {
        let ir = CircuitIR(nodes: [.ground, base.p, base.d, base.x], branches: [base.branch], instances: [
            .init(name: "Vp", typeName: "vsource", nodes: [base.p, base.d], parameters: ["v": .real(0)], ownedBranches: [base.branch]),
            .init(name: "Cd", typeName: "capacitor", nodes: [base.d, .ground], parameters: ["c": .real(2)]),
            .init(name: "Rd", typeName: "resistor", nodes: [base.d, .ground], parameters: ["r": .real(2)]),
            .init(name: "Rx", typeName: "resistor", nodes: [base.x, base.p], parameters: ["r": .real(4)])])
        return try NativeCircuitPreparer().prepareNativeConstitutive(ir: ir, registry: .standard(),
            operatingConditions: .init(temperatureKelvin: 300.15),
            limits: .init(maximumDeviceCount: 16, maximumMatrixDimension: 16, maximumAllocationBytes: 268_435_456),
            numericalLimits: .init(maximumAcceptedSteps: 10, maximumSolveAttempts: 10, maximumNewtonIterations: 10,
                maximumSavedScalars: 100, maximumMatrixDimension: 16, maximumWorkUnits: 1_000_000, maximumBreakpoints: 10),
            resources: resources, cancellation: cancellation)
    }
}
