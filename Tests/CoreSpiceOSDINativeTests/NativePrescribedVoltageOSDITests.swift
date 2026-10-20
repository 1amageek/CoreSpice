import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceParsedIR
import Foundation
import OSDIContracts
import OSDIRuntime
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Actual OSDI values on prescribed voltage images",
    .enabled(if: ProcessInfo.processInfo.environment["CORESPICE_GLOBAL_CHARGE_LINEAR_LIBRARY"] != nil,
        "Requires qualified original linear/parabola images and public operation-5 worker"),
    .timeLimit(.minutes(2)))
struct NativePrescribedVoltageOSDITests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var remaining: UInt64?; var refuseStorage = false
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var work: UInt64 { state.withLock { $0.work } }
        func arm(work: UInt64? = nil, storage: Bool = false) {
            state.withLock { $0.remaining = work; $0.refuseStorage = storage }
        }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                if let remaining = value.remaining {
                    guard units <= remaining else { throw Refusal.work }
                    value.remaining = remaining - units
                }
                guard units <= 8_000_000_000 - value.work else { throw Refusal.work }
                value.work += units
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try state.withLock { value in
                let current = kind == .liveOwnedBytes ? value.live : value.temporary
                guard !value.refuseStorage, byteCount <= 536_870_912 - current else { throw Refusal.storage }
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
    }

    /// Uses the real worker on a deliberately different box/context, or cancels inside its actual callback.
    private struct Evaluator: OSDIPrecisionConstitutiveEvaluating {
        enum Action: Sendable { case box, context(OSDIPrecisionContext), cancel(CancellationToken) }
        let action: Action
        func constructConstitutiveIdentities<Result>(session: inout OSDIPrecisionSession,
            lowerHigh: borrowing Span<Double>, lowerLow: borrowing Span<Double>,
            upperHigh: borrowing Span<Double>, upperLow: borrowing Span<Double>,
            lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext, precisionBits: UInt32,
            _ body: (OSDIPrecisionConstitutiveEvaluationView) -> Result)
            throws(OSDIPrecisionConstitutiveError) -> Result {
            let evaluator = OSDINativePrecisionEvaluator()
            switch action {
            case .box:
                let zero = [Double](repeating: 0, count: lowerHigh.count)
                return try evaluator.constructConstitutiveIdentities(session: &session,
                    lowerHigh: zero.span, lowerLow: zero.span, upperHigh: zero.span, upperLow: zero.span,
                    lowerContext: lowerContext, upperContext: upperContext, precisionBits: precisionBits, body)
            case .context(let wrong):
                return try evaluator.constructConstitutiveIdentities(session: &session,
                    lowerHigh: lowerHigh, lowerLow: lowerLow, upperHigh: upperHigh, upperLow: upperLow,
                    lowerContext: wrong, upperContext: wrong, precisionBits: precisionBits, body)
            case .cancel(let token):
                return try evaluator.constructConstitutiveIdentities(session: &session,
                    lowerHigh: lowerHigh, lowerLow: lowerLow, upperHigh: upperHigh, upperLow: upperLow,
                    lowerContext: lowerContext, upperContext: upperContext, precisionBits: precisionBits) { view in
                        token.cancel()
                        return body(view)
                    }
            }
        }
    }

    private func limits() -> NativePrescribedVoltageLimits {
        .init(maximumNativeTerms: 64, maximumRetainedBytes: 1_048_576,
            maximumWorkspaceBytes: 1_048_576, precisionBits: 192,
            reductionLimits: .init(maximumAxes: 16, maximumSources: 4,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    private func source(_ interval: ClosedRange<Double> = 0.5...0.5) -> NativePrescribedVoltageSource {
        .init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: 2,
            normalized: interval, leftSlope: 0.5...0.5, rightSlope: 1...1)
    }
    private func scalar(_ value: Double) throws -> E { try .init(center: .init(high: value)) }
    private func domain(_ owner: borrowing PreparedNativeCircuit, current: Branch,
        potential: ClosedRange<Double> = -2...2) throws -> NativeGlobalChargeDomain {
        let dimension = owner.plan.topology.dimension
        let row = try #require(owner.plan.topology.variableMap[.branchCurrent(current)])
        var lo = try [CompensatedValue](repeating: .init(high: potential.lowerBound), count: dimension)
        var hi = try [CompensatedValue](repeating: .init(high: potential.upperBound), count: dimension)
        // These are formal source-current coordinates, deliberately excluding zero.
        lo[row] = try .init(high: 2); hi[row] = try .init(high: 3)
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return .init(lower: lo, upper: hi, lowerContext: context, upperContext: context)
    }
    private func voltage(_ positive: Node, _ negative: Node, branch: Branch) -> Instance {
        // The selected equation is bound to explicit phi(U), independently of this ordinary DC datum.
        .init(name: "Vselected", typeName: "vsource", nodes: [positive, negative],
            parameters: ["v": .real(0)], ownedBranches: [branch])
    }
    private func passives(_ positive: Node, _ negative: Node) -> [Instance] {
        [Instance(name: "R4", typeName: "resistor", nodes: [positive, negative], parameters: ["r": .real(4)]),
         Instance(name: "C2", typeName: "capacitor", nodes: [positive, negative], parameters: ["c": .real(2)])]
    }
    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture, instances: [Instance],
        nodes: [Node], branches: [Branch], resources: Resources) async throws -> PreparedNativeCircuit {
        let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: instances.count,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let owner = try await NativeCircuitPreparer().prepare(
            ir: CircuitIR(nodes: nodes, branches: branches, instances: instances), registry: .standard(),
            operatingConditions: .init(temperatureKelvin: 300.15), limits: fixture.nativeLimits,
            numericalLimits: fixture.numerical, resources: resources, osdi: runtime,
            constitutive: fixture.snapshot, cancellation: .init())
        do {
            let programs = try #require(owner.record.constitutiveBacking?.programs)
            let foreign = instances.filter { $0.osdi != nil }
            try #require(programs.count == foreign.count)
            for index in programs.indices {
                let program = programs[index]
                try #require(program.modelReference == foreign[index].osdi?.resolved.binding.artifact)
                try #require(program.programDigest.hexadecimalValue == (program.modelReference == fixture.linear
                    ? "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203"
                    : "22bf1ebc619fcf7473d5845ad970638ef9a3a3123a8592b50538f522ebebc205"))
                try #require(program.topology.nodes.count == 2 && program.topology.activeUnknownCount == 2)
            }
        } catch { try owner.close(); throw error }
        return consume owner
    }
    private func check(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        branch: Branch, reduced: [E] = [], source: NativePrescribedVoltageSource? = nil,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageValues {
        try await owner.enclosePrescribedVoltageValues(originalDomain: domain(owner, current: branch),
            sources: [source ?? self.source()], reducedCoordinates: reduced, capture: fixture.capture,
            limits: limits(), cancellation: cancellation)
    }
    private func contains(_ enclosure: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = enclosure.center.bounds
        let lo = enclosure.radius == 0 ? bounds.lower : (bounds.lower - enclosure.radius).nextDown
        let hi = enclosure.radius == 0 ? bounds.upper : (bounds.upper + enclosure.radius).nextUp
        #expect(lo <= expected && expected <= hi, sourceLocation: sourceLocation)
        #expect(enclosure.radius < 1e-10, sourceLocation: sourceLocation)
    }
    private func containsRange(_ enclosure: E, _ expected: ClosedRange<Double>,
        sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = enclosure.center.bounds
        let lo = (bounds.lower - enclosure.radius).nextDown
        let hi = (bounds.upper + enclosure.radius).nextUp
        #expect(lo <= expected.lowerBound && hi >= expected.upperBound, sourceLocation: sourceLocation)
        #expect(lo >= expected.lowerBound - 1e-10 && hi <= expected.upperBound + 1e-10,
            sourceLocation: sourceLocation)
    }

    @Test func actualGroundedValuesRetainSourceOrientationFormalCurrentAndLease() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), branch = Branch(id: 0)
        do {
            for reversed in [false, true] {
                let owner = try await prepare(fixture, instances:
                    [voltage(reversed ? .ground : p, reversed ? p : .ground, branch: branch),
                     fixture.instance("Nlinear", nodes: [p, .ground])] + passives(p, .ground),
                    nodes: [.ground, p], branches: [branch], resources: resources)
                do {
                    let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                    let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                    let result = try await check(owner, fixture, branch: branch)
                    #expect(result.dimension == 2 && result.reducedCoordinateCount == 0)
                    #expect(result.selectedSourceCount == 1 && result.capturedSourceCount == 1)
                    let sign = reversed ? -1.0 : 1.0
                    contains(try result.sourceVoltage(at: 0), 1)
                    contains(try result.charge(at: pRow), 3 * sign)
                    contains(try result.staticResidual(at: pRow), 0.25 * sign)
                    contains(try result.staticResidual(at: iRow), 0)
                    contains(try result.charge(at: iRow), 0)
                    #expect(try result.coordinateLower(at: iRow) == CompensatedValue(high: 2))
                    #expect(try result.coordinateUpper(at: iRow) == CompensatedValue(high: 3))
                    let lo = try result.coordinateLower(at: pRow), hi = try result.coordinateUpper(at: pRow)
                    #expect(lo.high + lo.low <= sign && hi.high + hi.low >= sign)
                    if !reversed {
                        let interval = try await check(owner, fixture, branch: branch, source: source(0.25...0.75))
                        containsRange(try interval.sourceVoltage(at: 0), 0.5...1.5)
                        containsRange(try interval.charge(at: pRow), 1.5...4.5)
                        containsRange(try interval.staticResidual(at: pRow), 0.125...0.375)
                        contains(try interval.charge(at: iRow), 0)
                    }
                    try owner.close()
                    // The immutable values and their admission survive foreign-owner close.
                    contains(try result.charge(at: pRow), 3 * sign)
                    #expect(resources.live > 0)
                } catch { try owner.close(); throw error }
            }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func floatingImageSumsEveryRawAliasGroundAndNativeContribution() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        let p = Node(id: 1), n = Node(id: 2), branch = Branch(id: 0)
        do {
            let owner = try await prepare(fixture, instances:
                [voltage(p, n, branch: branch), fixture.instance("Nfloating", nodes: [p, n]),
                 fixture.instance("Nground", nodes: [n, .ground], capacitance: 2),
                 fixture.instance("Nalias", nodes: [n, n], capacitance: nil)] + passives(p, n),
                nodes: [.ground, p, n], branches: [branch], resources: resources)
            do {
                let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                let nRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(n)])
                let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                try #require(pRow < nRow)
                let result = try await check(owner, fixture, branch: branch, reduced: [scalar(0.5)])
                #expect(result.dimension == 3 && result.reducedCoordinateCount == 1)
                #expect(result.capturedSourceCount == 3 && result.selectedSourceCount == 1)
                // Smallest original potential is the floating root: p=.5, n=p-phi=-.5.
                // Qn=-3 (floating C) -1 (grounded C) -.5+.25 (both raw parabola rows).
                contains(try result.charge(at: pRow), 3)
                contains(try result.charge(at: nRow), -4.25)
                contains(try result.staticResidual(at: pRow), 0.25)
                contains(try result.staticResidual(at: nRow), -0.25)
                contains(try result.charge(at: iRow), 0)
                contains(try result.staticResidual(at: iRow), 0)
                #expect(try result.coordinateLower(at: iRow) == CompensatedValue(high: 2))
                #expect(try result.coordinateUpper(at: iRow) == CompensatedValue(high: 3))
                // This is only a value restriction of Q=(v,v^2); no full-domain kernel rank is inferred.
                contains(try result.sourceVoltage(at: 0), 1)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func wrongActualCoverScopeMissingCaptureAndOutsideDomainRefuseBeforePublication() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), branch = Branch(id: 0)
        do {
            let owner = try await prepare(fixture, instances: [voltage(p, .ground, branch: branch),
                fixture.instance("Nlinear", nodes: [p, .ground])], nodes: [.ground, p], branches: [branch], resources: resources)
            do {
                let original = try domain(owner, current: branch), baseline = resources.live + resources.temporary
                let wrongContext = try OSDIPrecisionContext(mode: .transient, timeHigh: 0, timeLow: 0)
                for action in [Evaluator.Action.box, .context(wrongContext)] {
                    do {
                        _ = try await owner.enclosePrescribedVoltageValues(originalDomain: original, sources: [source()],
                            reducedCoordinates: [], capture: fixture.replacingEvaluator(Evaluator(action: action)),
                            limits: limits(), cancellation: .init())
                        Issue.record("A different actual worker scope was published")
                    } catch OSDIConstitutiveCaptureFailure.control(let cause) {
                        guard case NativePrescribedVoltageFailure.invalidBinding = cause else { throw cause }
                    }
                    #expect(resources.live + resources.temporary == baseline)
                }
                await #expect(throws: NativePrescribedVoltageFailure.missingCaptureCapability) {
                    try await owner.enclosePrescribedVoltageValues(originalDomain: original, sources: [source()],
                        reducedCoordinates: [], capture: nil, limits: limits(), cancellation: .init())
                }
                let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                await #expect(throws: NativePrescribedVoltageFailure.outsideOriginalDomain(row: pRow)) {
                    try await owner.enclosePrescribedVoltageValues(
                        originalDomain: domain(owner, current: branch, potential: 0...0.5), sources: [source()],
                        reducedCoordinates: [], capture: fixture.capture, limits: limits(), cancellation: .init())
                }
                #expect(resources.live + resources.temporary == baseline)
                let result = try await check(owner, fixture, branch: branch)
                contains(try result.charge(at: pRow), 1)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func sharedQuotaAndActualCallbackCancellationRefundAndAllowSameOwnerRetry() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), branch = Branch(id: 0)
        do {
            let owner = try await prepare(fixture, instances: [voltage(p, .ground, branch: branch),
                fixture.instance("Nlinear", nodes: [p, .ground])], nodes: [.ground, p], branches: [branch], resources: resources)
            do {
                let baseline = resources.live + resources.temporary, work = resources.work
                resources.arm(work: 0)
                await #expect(throws: Refusal.work) { try await check(owner, fixture, branch: branch) }
                #expect(resources.live + resources.temporary == baseline)
                resources.arm(storage: true)
                await #expect(throws: Refusal.storage) { try await check(owner, fixture, branch: branch) }
                #expect(resources.live + resources.temporary == baseline)
                resources.arm()
                let cancelled = CancellationToken(); cancelled.cancel()
                do {
                    _ = try await check(owner, fixture, branch: branch, cancellation: cancelled)
                    Issue.record("Pre-cancelled composition published values")
                } catch NativeConstitutiveInspection.Failure.cancelled {}
                let callbackCancellation = CancellationToken()
                do {
                    _ = try await owner.enclosePrescribedVoltageValues(originalDomain: domain(owner, current: branch),
                        sources: [source()], reducedCoordinates: [],
                        capture: fixture.replacingEvaluator(Evaluator(action: .cancel(callbackCancellation))),
                        limits: limits(), cancellation: callbackCancellation)
                    Issue.record("Cancelled actual-worker callback published values")
                } catch OSDIConstitutiveCaptureFailure.control(let cause) {
                    guard case NativeConstitutiveInspection.Failure.cancelled = cause else { throw cause }
                }
                #expect(resources.live + resources.temporary == baseline)
                #expect(resources.work > work)
                let result = try await check(owner, fixture, branch: branch)
                let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                contains(try result.charge(at: pRow), 1)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
