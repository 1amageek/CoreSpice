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

@Suite("Actual-owned functional global charge kernel", .timeLimit(.minutes(1)))
struct NativeGlobalChargeKernelTests {
    private typealias S = ExactRowAlgebra.Scalar
    private enum Refusal: Error { case work, storage, cancelled }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0
            var temporary: UInt64 = 0
            var work: UInt64 = 0
            var reservations = 0
            var workRemaining: UInt64? = nil
            var storageRemaining: UInt64? = nil
            var cancelled = false
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var reservations: Int { state.withLock { $0.reservations } }
        func arm(work: UInt64? = nil, storage: UInt64? = nil, cancelled: Bool = false) {
            state.withLock { $0.workRemaining = work; $0.storageRemaining = storage; $0.cancelled = cancelled }
        }
        func checkCancellation() throws {
            if state.withLock({ $0.cancelled }) { throw Refusal.cancelled }
        }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                if let remaining = value.workRemaining {
                    guard units <= remaining else { throw Refusal.work }
                    value.workRemaining = remaining - units
                }
                let (next, overflow) = value.work.addingReportingOverflow(units)
                guard !overflow else { throw Refusal.work }; value.work = next
            }
        }
        func chargeHashedBytes(_ byteCount: UInt64) throws { try charge(.retainedElements, units: byteCount) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            try state.withLock { value in
                if let remaining = value.storageRemaining {
                    guard byteCount <= remaining else { throw Refusal.storage }
                }
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
                value.reservations += 1
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
    }
    private let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
        maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 16,
        maximumWorkUnits: 1_000_000, maximumBreakpoints: 10)
    private func nativeLimits(_ bytes: UInt64 = 16_777_216) -> SPICENativeExecutionLimits {
        .init(maximumDeviceCount: 16, maximumMatrixDimension: 16, maximumAllocationBytes: bytes)
    }
    private func limits(retained: Int = 131_072, workspace: Int = 1_048_576) -> NativeGlobalChargeLimits {
        .init(maximumNativeTerms: 128, maximumRetainedBytes: retained, maximumWorkspaceBytes: workspace,
            precisionBits: 192, exact: .init(maximumRows: 128, maximumColumns: 128,
                maximumIntegerBits: 4096, maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 131_072),
            regularity: .init(maximumDimension: 16, maximumMatrixNonzeros: 256,
                maximumInverseNonzeros: 256, maximumWorkspaceBytes: 1_048_576))
    }
    private func capacitor(_ name: String, _ positive: Node, _ negative: Node, _ c: Double = 2) -> Instance {
        .init(name: name, typeName: "capacitor", nodes: [positive, negative], parameters: ["c": .real(c)])
    }
    private func ir(_ instances: [Instance], nodes: [Node] = [.ground, .init(id: 1), .init(id: 2)],
        branches: [Branch] = []) -> CircuitIR { .init(nodes: nodes, branches: branches, instances: instances) }
    private func prepare(_ circuit: CircuitIR, resources: Resources = .init(), bytes: UInt64 = 16_777_216,
        cancellation: CancellationToken = .init()) throws -> PreparedNativeCircuit {
        try NativeCircuitPreparer().prepareNativeConstitutive(ir: circuit, registry: .standard(),
            operatingConditions: .init(temperatureKelvin: 300.15), limits: nativeLimits(bytes),
            numericalLimits: numerical, resources: resources, cancellation: cancellation)
    }
    private func context(_ time: Double = 0.5) throws -> OSDIPrecisionContext {
        try .init(mode: .transient, timeHigh: time, timeLow: 0)
    }
    private func domain(_ n: Int) throws -> NativeGlobalChargeDomain {
        .init(lower: [CompensatedValue](repeating: .zero, count: n),
            upper: try [CompensatedValue](repeating: .init(high: 2), count: n),
            lowerContext: try context(0), upperContext: try context(1))
    }
    private func anchor(_ values: [Double], time: Double = 0.5) throws -> NativeGlobalChargeAnchor {
        .init(coordinates: try values.map { try .init(high: $0) }, context: try context(time))
    }
    private func proposal(_ n: Int, rows: [[S]], anchors: [NativeGlobalChargeAnchor], inverse: [Double]) throws -> NativeGlobalChargeProposal {
        let r = n - rows.count
        return .init(nullRows: .init(rowCount: rows.count, columnCount: n, values: rows.flatMap { $0 }),
            anchors: anchors, inverse: try SparseStructure(dimension: r,
                rowPointers: (0...r).map { $0 * r }, columnIndices: (0..<(r * r)).map { $0 % r }), inverseValues: inverse)
    }
    private func check(_ owner: borrowing PreparedNativeCircuit, domain: NativeGlobalChargeDomain,
        proposal: NativeGlobalChargeProposal, selected: NativeGlobalChargeLimits? = nil,
        cancellation: CancellationToken = .init()) async throws -> NativeGlobalChargeKernel {
        try await owner.certifyGlobalChargeKernel(domain: domain, proposal: proposal, capture: nil,
            limits: selected ?? limits(), cancellation: cancellation)
    }
    private func contains(_ value: CompensatedEnclosure, _ exact: Double) -> Bool {
        let difference = value.center.high - exact
        return abs(difference + value.center.low) <= value.radius
    }

    @Test func floatingActualCapacitorsProveCompleteFunctionalKernelAndSumEveryInstance() async throws {
        let p = Node(id: 1), n = Node(id: 2), resources = Resources()
        let owner = try prepare(ir([capacitor("C1", p, n), capacitor("C2", n, p, 1)]), resources: resources)
        let baseline = resources.live
        do {
            let candidate = try proposal(2, rows: [[.one, .one]], anchors: [anchor([1, 0])], inverse: [-1.0 / 3])
            let result = try await check(owner, domain: domain(2), proposal: candidate)
            #expect(result.dimension == 2 && result.chargeSpanDimension == 1 && result.sourceInputCount == 0)
            #expect(result.nullRows.values == [.one, .one])
            #expect(contains(try result.anchorCharge(row: 0, anchor: 0), 3))
            #expect(contains(try result.anchorCharge(row: 1, anchor: 0), -3))
            guard case .regularMinor(let q) = result.rankWitness else { Issue.record("Missing minor witness"); return }
            #expect(q < 1 && q >= 0)
            #expect(resources.live > baseline && resources.temporary > 0)
        }
        #expect(resources.live == baseline && resources.temporary == 0)
    }

    @Test func groundAndReversedIncidenceRetainAllOriginalAxes() async throws {
        let p = Node(id: 1), n = Node(id: 2), branch = Branch(id: 0)
        let voltage = Instance(name: "V1", typeName: "vsource", nodes: [p, n], parameters: ["v": .real(0)], ownedBranches: [branch])
        let owner = try prepare(ir([capacitor("C1", .ground, p), voltage], branches: [branch]))
        let candidate = try proposal(3, rows: [[.zero, .one, .zero], [.zero, .zero, .one]],
            anchors: [anchor([1, 0, 0])], inverse: [0.5])
        let result = try await check(owner, domain: domain(3), proposal: candidate)
        #expect(result.dimension == 3 && result.chargeSpanDimension == 1)
        #expect(contains(try result.anchorCharge(row: 0, anchor: 0), 2))
        #expect(contains(try result.anchorCharge(row: 1, anchor: 0), 0))
        #expect(contains(try result.anchorCharge(row: 2, anchor: 0), 0))
    }

    @Test func actualSelfAliasCapacitorHasFullNullspaceWithoutZeroDimensionNumerics() async throws {
        let p = Node(id: 1)
        let owner = try prepare(ir([capacitor("C1", p, p)], nodes: [.ground, p]))
        let result = try await check(owner, domain: domain(1), proposal: proposal(1, rows: [[.one]], anchors: [], inverse: []))
        #expect(result.rankWitness == .fullNullspace && result.chargeSpanDimension == 0)
    }

    @Test func falseNullRowAndDependentBasisRefuseBeforeSuccess() async throws {
        let p = Node(id: 1), n = Node(id: 2)
        let owner = try prepare(ir([capacitor("C1", p, n)]))
        await #expect(throws: ExactRowAlgebra.Failure.inconsistentCertificate) {
            try await check(owner, domain: domain(2), proposal: proposal(2, rows: [[.one, .zero]],
                anchors: [anchor([1, 0])], inverse: [-0.5]))
        }
        await #expect(throws: ExactRowAlgebra.Failure.dependentBasis) {
            try await check(owner, domain: domain(2), proposal: proposal(2, rows: [[.one, .one], [.one, .one]], anchors: [], inverse: []))
        }
    }

    @Test func legalZeroAnchorsAndWrongInverseDoNotProveRank() async throws {
        let p = Node(id: 1), n = Node(id: 2)
        let owner = try prepare(ir([capacitor("C1", p, n)]))
        for (point, inverse) in [([0.0, 0], 0.5), ([1.0, 0], 0)] {
            await #expect(throws: ValidatedMatrixRegularity.Failure.uncertified) {
                try await check(owner, domain: domain(2), proposal: proposal(2, rows: [[.one, .one]],
                    anchors: [anchor(point)], inverse: [inverse]))
            }
        }
    }

    @Test func outsideAnchorTimeAndReversedDomainCannotBorrowAnotherScope() async throws {
        let p = Node(id: 1), n = Node(id: 2)
        let owner = try prepare(ir([capacitor("C1", p, n)]))
        for point in [try anchor([3, 0]), try anchor([1, 0], time: 2)] {
            await #expect(throws: NativeGlobalChargeFailure.illegalAnchor) {
                try await check(owner, domain: domain(2), proposal: proposal(2, rows: [[.one, .one]], anchors: [point], inverse: [-0.5]))
            }
        }
        let invalid = try NativeGlobalChargeDomain(lower: [.init(high: 2), .zero], upper: [.zero, .zero],
            lowerContext: try context(0), upperContext: try context(1))
        await #expect(throws: NativeGlobalChargeFailure.invalidDomain) {
            try await check(owner, domain: invalid, proposal: proposal(2, rows: [[.one, .one]], anchors: [anchor([1, 0])], inverse: [-0.5]))
        }
    }

    @Test func ordinaryOwnerDoesNotGainControlledProofAndNativeLaneRejectsOSDI() async throws {
        let p = Node(id: 1), n = Node(id: 2), circuit = ir([capacitor("C1", p, n)]), resources = Resources()
        let owner = try NativeCircuitPreparer().prepare(ir: circuit, registry: .standard(),
            operatingConditions: .init(temperatureKelvin: 300.15), limits: nativeLimits(), numericalLimits: numerical, resources: resources)
        await #expect(throws: NativeGlobalChargeFailure.missingControlledPreparation) {
            try await check(owner, domain: domain(2), proposal: proposal(2, rows: [[.one, .one]], anchors: [anchor([1, 0])], inverse: [-0.5]))
        }
        let before = resources.reservations
        let mixed = ir([capacitor("C1", p, n), .init(name: "N1", typeName: "osdi", nodes: [p], parameters: [:])])
        do { _ = try prepare(mixed, resources: resources); Issue.record("Native-only lane admitted OSDI") }
        catch SPICENativePreparationError.unsupportedCapability {}
        #expect(resources.reservations == before)
    }

    @Test func originalCancellationAndLimitsRefuseBeforeControlMetadata() throws {
        let p = Node(id: 1), resources = Resources(), circuit = ir([capacitor("C1", p, .ground)], nodes: [.ground, p])
        let cancelled = CancellationToken(); cancelled.cancel()
        do { _ = try prepare(circuit, resources: resources, cancellation: cancelled); Issue.record("Cancelled preparation admitted") }
        catch SPICENativePreparationError.resource(let error) {
            guard case NativeConstitutivePreparationControl.Failure.cancelled = error else { throw error }
        }
        #expect(resources.reservations == 0 && resources.live == 0 && resources.temporary == 0)
        do { _ = try prepare(circuit, resources: resources, bytes: 0); Issue.record("Invalid ceiling admitted") }
        catch SPICENativePreparationError.invalidLimits {}
        #expect(resources.reservations == 0)
    }

    @Test func sharedPreparationFloorCannotBeResetByAnotherProof() async throws {
        let p = Node(id: 1), n = Node(id: 2), resources = Resources()
        let owner = try prepare(ir([capacitor("C1", p, n)]), resources: resources)
        let control = try #require(owner.record.constitutiveBacking?.control)
        let baseline = resources.live
        let candidate = try proposal(2, rows: [[.one, .one]], anchors: [anchor([1, 0])], inverse: [-0.5])
        // Derive remaining headroom from the actual sealed preparation, never an estimated floor.
        var occupied: (any Sendable)? = try control.reserveStorage(byteCount:
            Int(owner.record.limits.maximumAllocationBytes - owner.record.compileCapacity - 4096))
        let held = resources.live + resources.temporary
        do { _ = try await check(owner, domain: domain(2), proposal: candidate); Issue.record("Checker reset shared floor") }
        catch NativeConstitutivePreparationControl.Failure.capacityExceeded {}
        #expect(resources.live + resources.temporary == held)
        withExtendedLifetime(occupied) {}; occupied = nil
        #expect(resources.live == baseline && resources.temporary == 0)
        do { _ = try await check(owner, domain: domain(2), proposal: candidate) }
        #expect(resources.live == baseline && resources.temporary == 0)
    }

    @Test func failureRefundsAndRetainedScalarCopyKeepsOriginalOwnerAdmission() async throws {
        let p = Node(id: 1), n = Node(id: 2), resources = Resources()
        let owner = try prepare(ir([capacitor("C1", p, n)]), resources: resources)
        let baseline = resources.live
        let candidate = try proposal(2, rows: [[.one, .one]], anchors: [anchor([1, 0])], inverse: [-0.5])
        resources.arm(work: 0)
        await #expect(throws: Refusal.work) { try await check(owner, domain: domain(2), proposal: candidate) }
        resources.arm(storage: 0)
        await #expect(throws: Refusal.storage) { try await check(owner, domain: domain(2), proposal: candidate) }
        resources.arm()
        await #expect(throws: NativeGlobalChargeFailure.capacityExceeded) {
            try await check(owner, domain: domain(2), proposal: candidate, selected: limits(retained: 1))
        }
        #expect(resources.live == baseline && resources.temporary == 0)
        var extracted: S? = nil
        do {
            let result = try await check(owner, domain: domain(2), proposal: candidate)
            extracted = result.nullRows.values[0]
        }
        #expect(extracted == .one && resources.live > baseline && resources.temporary == 0)
        extracted = nil
        #expect(resources.live == baseline)
        let cancelled = CancellationToken(); cancelled.cancel()
        do { _ = try await check(owner, domain: domain(2), proposal: candidate, cancellation: cancelled); Issue.record("Cancelled proof admitted") }
        catch NativeConstitutiveInspection.Failure.cancelled {}
        #expect(resources.live == baseline && resources.temporary == 0)
        #expect(try await check(owner, domain: domain(2), proposal: candidate).chargeSpanDimension == 1)
    }
}
