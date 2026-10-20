import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceParsedIR
import Foundation
import Synchronization
import Testing
import CoreSpice

@Suite("Public conditional prescribed-source flow", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageFlowTests {
    typealias E = CompensatedEnclosure
    enum Refusal: Error, Equatable { case work, storage }
    final class Resources: SPICESourceResourceAccounting {
        struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0; var reservations = 0; var remaining: UInt64?; var deny = false }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var work: UInt64 { state.withLock { $0.work } }
        var reservations: Int { state.withLock { $0.reservations } }
        func arm(work: UInt64? = nil, deny: Bool = false) { state.withLock { $0.remaining = work; $0.deny = deny } }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { s in
                if let remaining = s.remaining { guard units <= remaining else { throw Refusal.work }; s.remaining = remaining - units }
                let (next, overflow) = s.work.addingReportingOverflow(units)
                guard !overflow, next <= 8_000_000_000 else { throw Refusal.work }; s.work = next
            }
        }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try charge(.retainedElements, units: byteCount) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            try state.withLock { s in
                let current = kind == .liveOwnedBytes ? s.live : s.temporary
                guard !s.deny, byteCount <= 536_870_912 - current else { throw Refusal.storage }
                if kind == .liveOwnedBytes { s.live += byteCount } else { s.temporary += byteCount }; s.reservations += 1
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { s in
                if kind == .liveOwnedBytes { s.live -= byteCount } else { s.temporary -= byteCount }
            }}
        }
    }
    let p = Node(id: 1), d = Node(id: 2), x = Node(id: 3), branch = Branch(id: 0)
    func e(_ lo: Double, _ hi: Double) throws -> E { try .init(center: .init(high: lo / 2 + hi / 2), radius: (hi - lo) / 2) }
    func proposal(_ coordinates: [E], initial: Bool) throws -> NativePrescribedVoltageFlowRootProposal {
        .init(coordinates: coordinates, center: try [.init(high: 0.5), .init(high: 1)],
            inverse: try .init(dimension: 2, rowPointers: [0, 1, 2], columnIndices: [0, 1]),
            inverseValues: initial ? [1, 4] : [0.5, 4])
    }
    func source(initial: ClosedRange<Double> = 0.5...0.5, window: ClosedRange<Double> = 0.5...0.5,
        slope: ClosedRange<Double> = 0...0) -> NativePrescribedVoltageFlowSource {
        .init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: 2,
            initialNormalized: initial, normalized: window, normalizedDerivativePerSecond: slope)
    }
    func request(duration: Double = 0.125, wideInitial: Bool = false, charge: ClosedRange<Double> = 0...2,
        source input: NativePrescribedVoltageFlowSource? = nil) throws -> NativePrescribedVoltageFlowRequest {
        .init(originalLower: try [0.0, -4, -4, -10].map { try .init(high: $0) },
            originalUpper: try [2.0, 4, 4, 10].map { try .init(high: $0) },
            startTime: try .init(high: 0.25, low: 0x1p-60), duration: try .init(high: duration),
            sources: [input ?? source()], algebraicRows: [1], dynamicInitialCoordinates: [try e(0.49, 0.51)],
            initial: try proposal([e(0.4, 0.6), e(wideInitial ? -1 : 0.8, wideInitial ? 3 : 1.2)], initial: true),
            chargeBox: [try e(charge.lowerBound, charge.upperBound)],
            window: try proposal([e(-0.5, 1.5), e(0.5, 1.5)], initial: false))
    }
    func limits(resultBytes: Int = 1_048_576, workspaceBytes: Int = 1_048_576) -> NativePrescribedVoltageFlowLimits {
        let c = NativePrescribedVoltageFlowLimits.Capacity(maximumRetainedBytes: 2_097_152, maximumWorkspaceBytes: 2_097_152)
        return .init(maximumNativeTerms: 128, maximumTriplets: 128, maximumPreconditionerNonzeros: 128,
            maximumIntegerBits: 4096, precisionBits: 192, values: c, reduction: c, chart: c, exact: c, root: c,
            evolution: c, result: .init(maximumRetainedBytes: resultBytes, maximumWorkspaceBytes: workspaceBytes))
    }
    func fixture(resources: Resources = .init(), isolated: Bool = false, controlled: Bool = true) throws -> PreparedNativeCircuit {
        var instances: [Instance] = [
            .init(name: "Vp", typeName: "vsource", nodes: [p, .ground], parameters: ["v": .real(0)], ownedBranches: [branch]),
            .init(name: "Cd", typeName: "capacitor", nodes: [d, .ground], parameters: ["c": .real(2)]),
            .init(name: "Rx", typeName: "resistor", nodes: [x, p], parameters: ["r": .real(4)])]
        if !isolated { instances.append(.init(name: "Rd", typeName: "resistor", nodes: [d, p], parameters: ["r": .real(2)])) }
        let ir = CircuitIR(nodes: [.ground, p, d, x], branches: [branch], instances: instances)
        let native = SPICENativeExecutionLimits(maximumDeviceCount: 16, maximumMatrixDimension: 16, maximumAllocationBytes: 268_435_456)
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10, maximumNewtonIterations: 10,
            maximumSavedScalars: 100, maximumMatrixDimension: 16, maximumWorkUnits: 1_000_000, maximumBreakpoints: 10)
        if controlled {
            let preparer: any NativeConstitutiveCircuitPreparing = NativeCircuitPreparer()
            return try preparer.prepareNativeConstitutive(ir: ir, registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15),
                limits: native, numericalLimits: numerical, resources: resources, cancellation: .init())
        }
        return try NativeCircuitPreparer().prepare(ir: ir, registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15),
            limits: native, numericalLimits: numerical, resources: resources)
    }
    func flow(_ owner: borrowing PreparedNativeCircuit, _ request: NativePrescribedVoltageFlowRequest,
        limits: NativePrescribedVoltageFlowLimits? = nil, cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageFlow {
        try await owner.certifyPrescribedVoltageFlow(request: request, capture: nil, range: nil,
            limits: limits ?? self.limits(), cancellation: cancellation)
    }
    func contains(_ enclosure: E, _ value: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let b = enclosure.center.bounds
        #expect((b.lower - enclosure.radius).nextDown <= value && value <= (b.upper + enclosure.radius).nextUp, sourceLocation: sourceLocation)
    }

    @Test func activeRCUsesActualNonzeroFieldAndLipschitzAndEnclosesTheAnalyticEndpoint() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources)
            do {
                let r = try request(), result = try await flow(owner, r)
                #expect(result.dimension == 4 && result.chargeCoordinateCount == 1 && result.selectedSourceCount == 1)
                #expect(result.contractionUpperBound > 0 && result.contractionUpperBound < 1)
                contains(try result.chargeRateAlmostEverywhere(at: 0), 0.25)
                contains(try result.selectedCurrentAlmostEverywhere(at: 0), -0.25)
                let exact = 2 + (1 - 2) * exp(-r.duration.high / 4)
                contains(try result.endpointCharge(at: 0), exact)
                let reservationCount = resources.reservations
                for _ in 0..<128 {
                    result.withScope { scope in
                        let sources = scope.sources.count, models = scope.models.count
                        #expect(sources == 1 && models == 0)
                        #expect(scope.preparation.plan.ir.instances.count == 4)
                        let actual = scope.sources[0]
                        #expect(actual.fact.instance.name == "Vp" && actual.fact.positiveNode == p && actual.fact.negativeNode == .ground)
                        #expect(scope.startTime == r.startTime && scope.initialContext.timeLow.bitPattern == r.startTime.low.bitPattern)
                        contains(scope.initialCharge[0], 1)
                        #expect(scope.windowUpperContext.timeHigh >= scope.initialContext.timeHigh)
                    }
                }
                #expect(resources.reservations == reservationCount)
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func identicalWideSourceEnclosuresJoinTheCompleteConditionalFlow() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources, isolated: true)
            do {
                let input = NativePrescribedVoltageFlowSource(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 1,
                    timeOrigin: 0, timeScale: 2, initialNormalized: 0...1, normalized: 0...1,
                    normalizedDerivativePerSecond: -0.5...0.5)
                let proposed = NativePrescribedVoltageFlowRequest(
                    originalLower: try [-1.0, -4, -4, -10].map { try .init(high: $0) },
                    originalUpper: try [2.0, 4, 4, 10].map { try .init(high: $0) },
                    startTime: try .init(high: 0.25, low: 0x1p-60), duration: try .init(high: 0.125),
                    sources: [input], algebraicRows: [1], dynamicInitialCoordinates: [try e(0.49, 0.51)],
                    initial: try proposal([e(0.4, 0.6), e(-0.25, 1.25)], initial: true),
                    chargeBox: [try e(0, 2)],
                    window: try proposal([e(-0.5, 1.5), e(-0.5, 1.5)], initial: false))
                let result = try await flow(owner, proposed)
                let row = try #require(result.withScope { $0.preparation.plan.topology.variableMap[.nodeVoltage(p)] })
                contains(try result.coordinate(at: row), 0)
                contains(try result.coordinate(at: row), 1)
                contains(try result.endpointCharge(at: 0), 1)
                #expect(result.contractionUpperBound == 0)
                result.withScope { scope in
                    let actual = scope.sources[0].assumptions
                    #expect(actual.initialNormalized == (0...1) && actual.normalized == (0...1))
                    #expect(actual.normalizedDerivativePerSecond == (-0.5...0.5))
                }
            } catch { try owner.close(); throw error }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func unequalInitialSourceOutsideTheWindowStillRefuses() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources, isolated: true)
            let baseline = resources.live + resources.temporary
            do {
                _ = try await flow(owner, request(source: source(initial: 0...1, window: 0.25...0.75)))
                Issue.record("Unequal initial source outside the window was admitted")
            } catch NativePrescribedVoltageFlowFailure.invalidInput {}
            #expect(resources.live + resources.temporary == baseline)
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func fullInitialBoxMustBelongToWindowEvenWhenTheRootAndChargeWouldFit() async throws {
        let owner = try fixture()
        do { _ = try await flow(owner, request(wideInitial: true)); Issue.record("Different chart domain joined only by q0") }
        catch NativePrescribedVoltageFlowFailure.uncertified(let phase, _) { #expect(phase == .branchJoin) }
        try owner.close()
    }

    @Test func initialChargeAndContractionRefuseWithoutIndependentCallerFieldOrCharge() async throws {
        let owner = try fixture()
        do { _ = try await flow(owner, request(charge: 1.5...1.75)); Issue.record("Actual q0 outside Q admitted") }
        catch NativePrescribedVoltageFlowFailure.uncertified(let phase, _) { #expect(phase == .branchJoin) }
        do { _ = try await flow(owner, request(duration: 1)); Issue.record("Noncontractive actual charge field admitted") }
        catch NativePrescribedVoltageFlowFailure.uncertified(let phase, _) { #expect(phase == .picard) }
        try owner.close()
    }

    @Test func oneSIDerivativeBoundIsRetainedWithoutEverywhereOneSidedDerivativeAuthority() async throws {
        let owner = try fixture(isolated: true)
        let r = try request(source: source(slope: -0.5...0.5))
        let result = try await flow(owner, r)
        #expect(result.contractionUpperBound == 0)
        result.withScope { scope in
            let actual = scope.sources[0]
            #expect(actual.assumptions.normalizedDerivativePerSecond == (-0.5...0.5))
            #expect(actual.internalNormalizedSlope.lowerBound <= -1 && actual.internalNormalizedSlope.upperBound >= 1)
        }
        contains(try result.endpointCharge(at: 0), 1)
        try owner.close()
    }

    @Test func ordinaryPreparationAndUncontainedSourceSlicesDoNotGainAuthority() async throws {
        let ordinary = try fixture(controlled: false)
        do { _ = try await flow(ordinary, request()); Issue.record("Ordinary owner acquired a new control implicitly") }
        catch NativePrescribedVoltageFlowFailure.missingControlledPreparation {}
        try ordinary.close()
        let owner = try fixture()
        do { _ = try await flow(owner, request(source: source(initial: 0.25...0.75))); Issue.record("Initial U outside window joined") }
        catch NativePrescribedVoltageFlowFailure.invalidInput {}
        try owner.close()
    }

    @Test func sharedWorkCoexistenceCopiedScopeElementsAndFinalRefundKeepOneOwner() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources), r = try request()
            let baseline = resources.live + resources.temporary
            for limit in [limits(resultBytes: 1), limits(workspaceBytes: 1)] {
                do { _ = try await flow(owner, r, limits: limit); Issue.record("Flow capacity ignored") }
                catch NativePrescribedVoltageFlowFailure.capacityExceeded {}
                #expect(resources.live + resources.temporary == baseline)
            }
            resources.arm(deny: true)
            do { _ = try await flow(owner, r); Issue.record("Source storage denial ignored") }
            catch NativePrescribedVoltageFlowFailure.phase(_, let error) { guard case Refusal.storage = error else { throw error } }
            resources.arm()
            let token = CancellationToken(); token.cancel()
            do { _ = try await flow(owner, r, cancellation: token); Issue.record("Cancelled flow published") }
            catch NativePrescribedVoltageFlowFailure.cancelled {}
            let before = resources.work
            do { let result = try await flow(owner, r); contains(try result.endpointCharge(at: 0), 1) }
            let cost = resources.work - before
            #expect(cost > 1 && resources.live + resources.temporary == baseline)
            try resources.charge(.retainedElements, units: 17); resources.arm(work: cost - 1)
            do { _ = try await flow(owner, r); Issue.record("Flow reset prior spent work") }
            catch NativePrescribedVoltageFlowFailure.phase(_, let error) { guard case Refusal.work = error else { throw error } }
            resources.arm()
            #expect(resources.live + resources.temporary == baseline)
            var first: NativePrescribedVoltageFlow? = try await flow(owner, r)
            var copy = first
            var source: NativePrescribedVoltageFlowSourceScope?
            try #require(copy).withScope { source = $0.sources[0] }
            first = nil; try owner.close()
            contains(try #require(copy).endpointCharge(at: 0), 1)
            copy = nil
            #expect(resources.live + resources.temporary > baseline)
            #expect(source?.fact.instance.name == "Vp")
            source = nil
            #expect(resources.live + resources.temporary == baseline)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
