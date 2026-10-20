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

@Suite("Actual source-bound global charge composition",
    .enabled(if: ProcessInfo.processInfo.environment["CORESPICE_GLOBAL_CHARGE_LINEAR_LIBRARY"] != nil,
        "Requires qualified original linear/parabola images and public operation-5 worker"),
    .timeLimit(.minutes(2)))
struct NativeGlobalChargeOSDITests {
    private typealias S = ExactRowAlgebra.Scalar
    private enum Refusal: Error { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var remaining: UInt64? = nil; var refuseStorage = false
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var work: UInt64 { state.withLock { $0.work } }
        func arm(work: UInt64? = nil, storage: Bool = false) { state.withLock { $0.remaining = work; $0.refuseStorage = storage } }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                if let remaining = value.remaining {
                    guard units <= remaining else { throw Refusal.work }; value.remaining = remaining - units
                }
                guard units <= 8_000_000_000 - value.work else { throw Refusal.work }; value.work += units
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try state.withLock { value in
                guard !value.refuseStorage else { throw Refusal.storage }
                let current = kind == .liveOwnedBytes ? value.live : value.temporary
                guard byteCount <= 536_870_912 - current else { throw Refusal.storage }
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
    }
    /// The real worker is deliberately queried on a different scope. No forged view is constructed.
    private struct DifferentScope: OSDIPrecisionConstitutiveEvaluating {
        let changeBox: Bool
        let context: OSDIPrecisionContext
        func constructConstitutiveIdentities<Result>(session: inout OSDIPrecisionSession,
            lowerHigh: borrowing Span<Double>, lowerLow: borrowing Span<Double>,
            upperHigh: borrowing Span<Double>, upperLow: borrowing Span<Double>,
            lowerContext: OSDIPrecisionContext, upperContext: OSDIPrecisionContext, precisionBits: UInt32,
            _ body: (OSDIPrecisionConstitutiveEvaluationView) -> Result) throws(OSDIPrecisionConstitutiveError) -> Result {
            if changeBox {
                let zero = [Double](repeating: 0, count: lowerHigh.count)
                return try OSDINativePrecisionEvaluator().constructConstitutiveIdentities(session: &session,
                    lowerHigh: zero.span, lowerLow: zero.span, upperHigh: zero.span, upperLow: zero.span,
                    lowerContext: lowerContext, upperContext: upperContext, precisionBits: precisionBits, body)
            }
            return try OSDINativePrecisionEvaluator().constructConstitutiveIdentities(session: &session,
                lowerHigh: lowerHigh, lowerLow: lowerLow, upperHigh: upperHigh, upperLow: upperLow,
                lowerContext: context, upperContext: context, precisionBits: precisionBits, body)
        }
    }
    private func limits() -> NativeGlobalChargeLimits {
        .init(maximumNativeTerms: 32, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576,
            precisionBits: 192, exact: .init(maximumRows: 64, maximumColumns: 64, maximumIntegerBits: 4096,
                maximumWorkspaceBytes: 2_097_152, maximumResultBytes: 1_048_576),
            regularity: .init(maximumDimension: 16, maximumMatrixNonzeros: 256,
                maximumInverseNonzeros: 256, maximumWorkspaceBytes: 1_048_576))
    }
    private func context(_ t: Double = 0.25) throws -> OSDIPrecisionContext { try .init(mode: .transient, timeHigh: t, timeLow: 0) }
    private func domain(_ n: Int) throws -> NativeGlobalChargeDomain {
        try .init(lower: [CompensatedValue](repeating: .init(high: -1), count: n),
            upper: [CompensatedValue](repeating: .init(high: 1), count: n), lowerContext: context(), upperContext: context())
    }
    private func anchor(_ x: [Double]) throws -> NativeGlobalChargeAnchor {
        try .init(coordinates: x.map { try .init(high: $0) }, context: context())
    }
    private func proposal(_ n: Int, _ rows: [[S]], _ anchors: [[Double]], _ inverse: [Double]) throws -> NativeGlobalChargeProposal {
        let r = n - rows.count
        return try .init(nullRows: .init(rowCount: rows.count, columnCount: n, values: rows.flatMap { $0 }),
            anchors: anchors.map { try anchor($0) }, inverse: .init(dimension: r,
                rowPointers: (0...r).map { $0 * r }, columnIndices: (0..<(r*r)).map { $0 % r }), inverseValues: inverse)
    }
    private func check(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        _ candidate: NativeGlobalChargeProposal, capture: OSDIConstitutiveCaptureInputs? = nil,
        cancellation: CancellationToken = .init()) async throws -> NativeGlobalChargeKernel {
        try await owner.certifyGlobalChargeKernel(domain: domain(owner.plan.topology.dimension), proposal: candidate,
            capture: capture ?? fixture.capture, limits: limits(), cancellation: cancellation)
    }
    private func contains(_ enclosure: CompensatedEnclosure, _ value: Double) -> Bool {
        abs((enclosure.center.high - value) + enclosure.center.low) <= enclosure.radius
    }
    private func requireSourceRefusal(_ body: () async throws -> Void, cause expected: NativeGlobalChargeFailure) async throws {
        do { try await body(); Issue.record("Mismatched source scope admitted") }
        catch OSDIConstitutiveCaptureFailure.control(let cause) {
            switch (cause, expected) {
            case (NativeGlobalChargeFailure.invalidBinding, .invalidBinding),
                 (NativeGlobalChargeFailure.unprovedNullRow, .unprovedNullRow): break
            default: throw cause
            }
        }
    }

    @Test func floatingActualOSDIAndNativeCapacitorUseOneGlobalAnchor() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), n = Node(id: 2)
        do {
            let native = Instance(name: "C1", typeName: "capacitor", nodes: [p, n], parameters: ["c": .real(2)])
            let owner = try await fixture.prepare([fixture.instance("N1", nodes: [p, n]), native], nodes: [.ground, p, n], resources: resources)
            do {
                let result = try await check(owner, fixture, proposal(2, [[.one, .one]], [[1, 0]], [-1.0 / 3]))
                #expect(result.chargeSpanDimension == 1 && result.sourceInputCount == 1)
                #expect(contains(try result.anchorCharge(row: 0, anchor: 0), 3))
                #expect(contains(try result.anchorCharge(row: 1, anchor: 0), -3))
                try owner.close()
                // Retained mathematical facts remain inspectable after the foreign execution owner closes.
                #expect(contains(try result.anchorCharge(row: 1, anchor: 0), -3))
            } catch { try owner.close(); throw error }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func groundZeroPullbackAndAliasedRawRowsAreNotLost() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1)
        do {
            do {
                let owner = try await fixture.prepare([fixture.instance("Nground", nodes: [p, .ground])], nodes: [.ground, p], resources: resources)
                do {
                    try await requireSourceRefusal({ _ = try await check(owner, fixture, proposal(1, [[.one]], [], [])) }, cause: .unprovedNullRow)
                    let result = try await check(owner, fixture, proposal(1, [], [[1]], [1]))
                    #expect(result.chargeSpanDimension == 1)
                    #expect(contains(try result.anchorCharge(row: 0, anchor: 0), 1))
                } catch { try owner.close(); throw error }
                try owner.close()
            }
            do {
                let owner = try await fixture.prepare([fixture.instance("Nalias", nodes: [p, p], capacitance: nil)], nodes: [.ground, p], resources: resources)
                do {
                    let result = try await check(owner, fixture, proposal(1, [], [[1]], [0.5]))
                    #expect(result.chargeSpanDimension == 1)
                    #expect(contains(try result.anchorCharge(row: 0, anchor: 0), 2))
                } catch { try owner.close(); throw error }
                try owner.close()
            }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func oppositeActualInstancesRefuseCompletenessSpecificallyAtMinorRank() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), n = Node(id: 2)
        do {
            // One candidate must distinguish Q=(2t,-2t) from Q=(0,0), including the strict norm boundary.
            let candidate = try proposal(2, [[.one, .one]], [[1, 0]], [-0.5])
            for negative in [false, true] {
                let owner = try await fixture.prepare([fixture.instance("Nplus", nodes: [p, n], capacitance: 1),
                    fixture.instance("Nsecond", nodes: [p, n], capacitance: negative ? -1 : 1)],
                    nodes: [.ground, p, n], resources: resources)
                do {
                    let baseline = resources.live + resources.temporary
                    if negative {
                        await #expect(throws: ValidatedMatrixRegularity.Failure.uncertified) {
                            try await check(owner, fixture, candidate)
                        }
                    } else {
                        let result = try await check(owner, fixture, candidate)
                        #expect(result.chargeSpanDimension == 1 && result.sourceInputCount == 2)
                        #expect(contains(try result.anchorCharge(row: 0, anchor: 0), 2))
                        #expect(contains(try result.anchorCharge(row: 1, anchor: 0), -2))
                    }
                    #expect(resources.live + resources.temporary == baseline)
                } catch { try owner.close(); throw error }
                try owner.close()
            }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func nonlinearFunctionalSpanUsesTwoLegalValuesAndNeverAnchorOnlyIdentity() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), q = Node(id: 2)
        do {
            let owner = try await fixture.prepare([fixture.instance("Nparabola", nodes: [p, q], capacitance: nil)], nodes: [.ground, p, q], resources: resources)
            do {
                // Q=(-1,1),(1,1) is invertible, while DQ has only one nonzero column everywhere.
                let result = try await check(owner, fixture, proposal(2, [], [[-1, 0], [1, 0]], [-0.5, 0.5, 0.5, 0.5]))
                #expect(result.chargeSpanDimension == 2 && result.nullRows.rowCount == 0)
                #expect(contains(try result.anchorCharge(row: 0, anchor: 0), -1))
                #expect(contains(try result.anchorCharge(row: 1, anchor: 0), 1))
                #expect(contains(try result.anchorCharge(row: 0, anchor: 1), 1))
                #expect(contains(try result.anchorCharge(row: 1, anchor: 1), 1))
                try await requireSourceRefusal({ _ = try await check(owner, fixture,
                    proposal(2, [[.zero, .one]], [[0, 0]], [1])) }, cause: .unprovedNullRow)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func wrongSourceScopeMissingCaptureAndSharedRefusalsPublishNothing() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), n = Node(id: 2)
        do {
            let owner = try await fixture.prepare([fixture.instance("N1", nodes: [p, n])], nodes: [.ground, p, n], resources: resources)
            do {
                let candidate = try proposal(2, [[.one, .one]], [[1, 0]], [-1]), baseline = resources.live + resources.temporary
                for box in [true, false] {
                    let wrong = fixture.replacingEvaluator(DifferentScope(changeBox: box, context: try context(0)))
                    try await requireSourceRefusal({ _ = try await check(owner, fixture, candidate, capture: wrong) }, cause: .invalidBinding)
                    #expect(resources.live + resources.temporary == baseline)
                }
                await #expect(throws: NativeGlobalChargeFailure.missingCaptureCapability) {
                    try await owner.certifyGlobalChargeKernel(domain: domain(2), proposal: candidate,
                        capture: nil, limits: limits(), cancellation: .init())
                }
                resources.arm(work: 0)
                await #expect(throws: Refusal.work) { try await check(owner, fixture, candidate) }
                resources.arm(storage: true)
                await #expect(throws: Refusal.storage) { try await check(owner, fixture, candidate) }
                resources.arm()
                let cancelled = CancellationToken(); cancelled.cancel()
                do { _ = try await check(owner, fixture, candidate, cancellation: cancelled); Issue.record("Cancelled composition published") }
                catch NativeConstitutiveInspection.Failure.cancelled {}
                #expect(resources.live + resources.temporary == baseline)
                let result = try await check(owner, fixture, candidate)
                #expect(result.chargeSpanDimension == 1)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
