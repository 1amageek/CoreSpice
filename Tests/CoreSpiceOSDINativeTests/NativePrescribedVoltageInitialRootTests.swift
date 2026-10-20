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

@Suite("Actual native initial coordinate roots", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageInitialRootTests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var refuseStorage = false; var work: UInt64? = nil; var units: UInt64 = 0; var peak: UInt64 = 0 }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var units: UInt64 { state.withLock { $0.units } }
        var peak: UInt64 { state.withLock { $0.peak } }
        func arm(storage: Bool = false, work: UInt64? = nil) { state.withLock { $0.refuseStorage = storage; $0.work = work } }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                value.units += units
                guard let remaining = value.work else { return }
                guard units <= remaining else { throw Refusal.work }; value.work = remaining - units
            }
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
    private func scalar(_ x: Double) throws -> E { try .init(center: .init(high: x)) }
    private func context(_ time: Double = 0.25) throws -> OSDIPrecisionContext { try .init(mode: .transient, timeHigh: time, timeLow: 0) }
    private func domain(_ lo: [Double], _ hi: [Double]) throws -> NativeGlobalChargeDomain {
        try .init(lower: lo.map { try .init(high: $0) }, upper: hi.map { try .init(high: $0) },
            lowerContext: context(), upperContext: context())
    }
    private func limits(retained: Int = 131_072) -> NativePrescribedVoltageLimits {
        .init(maximumNativeTerms: 16_384, maximumRetainedBytes: retained, maximumWorkspaceBytes: 1_048_576,
            precisionBits: 192, reductionLimits: .init(maximumAxes: 16_384, maximumSources: 8,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    private func source(_ index: Int = 0, u: ClosedRange<Double> = 0.5...0.5, scale: Double = 2, one: Double = 2, left: Double = 1, right: Double = 1) -> NativePrescribedVoltageSource {
        .init(deviceIndex: index, zeroVoltage: 0, oneVoltage: one, timeOrigin: 0, timeScale: scale,
            normalized: u, leftSlope: left...left, rightSlope: right...right)
    }
    private func voltage(_ name: String = "V1", positive: Node, negative: Node, branch: Branch = .init(id: 0),
        parameters: [String: ParameterValue] = ["v": .real(0)]) -> Instance {
        .init(name: name, typeName: "vsource", nodes: [positive, negative], parameters: parameters, ownedBranches: [branch])
    }
    private func prepare(_ instances: [Instance], nodes: [Node], branches: [Branch] = [.init(id: 0)],
        resources: Resources = .init(), controlled: Bool = true) throws -> PreparedNativeCircuit {
        var names: [Branch: String] = [:]
        for instance in instances where instance.typeName == "vsource" {
            for branch in instance.ownedBranches { names[branch] = instance.name }
        }
        let circuit = CircuitIR(nodes: nodes, branches: branches, instances: instances, branchNames: names)
        let dimension = nodes.count - 1 + branches.count
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: dimension * 2, maximumMatrixDimension: dimension,
            maximumWorkUnits: 1_000_000, maximumBreakpoints: 10)
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: instances.count + 1, maximumMatrixDimension: dimension, maximumAllocationBytes: 268_435_456)
        if controlled {
            return try NativeCircuitPreparer().prepareNativeConstitutive(ir: circuit, registry: .standard(),
                operatingConditions: .init(temperatureKelvin: 300.15), limits: limits, numericalLimits: numerical,
                resources: resources, cancellation: .init())
        }
        return try NativeCircuitPreparer().prepare(ir: circuit, registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15),
            limits: limits, numericalLimits: numerical, resources: resources)
    }
    private func values(_ owner: borrowing PreparedNativeCircuit, _ d: NativeGlobalChargeDomain,
        _ sources: [NativePrescribedVoltageSource], z: [E] = [], retained: Int = 131_072,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageValues {
        try await owner.enclosePrescribedVoltageValues(originalDomain: d, sources: sources, reducedCoordinates: z,
            capture: nil, limits: limits(retained: retained), cancellation: cancellation)
    }
    private func contains(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = value.center.bounds
        let lo = value.radius == 0 ? bounds.lower : (bounds.lower - value.radius).nextDown
        let hi = value.radius == 0 ? bounds.upper : (bounds.upper + value.radius).nextUp
        #expect(lo <= expected && expected <= hi, sourceLocation: sourceLocation)
    }

    private func fixture(resources: Resources = .init()) throws -> PreparedNativeCircuit {
        let p = Node(id: 1), d = Node(id: 2), x = Node(id: 3)
        return try prepare([voltage(positive: p, negative: .ground),
            .init(name: "Cd", typeName: "capacitor", nodes: [d, .ground], parameters: ["c": .real(2)]),
            .init(name: "Rx", typeName: "resistor", nodes: [x, p], parameters: ["r": .real(4)])],
            nodes: [.ground, p, d, x], resources: resources)
    }
    private func chartLimits(triplets: Int = 64, retained: Int = 1_048_576, workspace: Int = 1_048_576) -> NativePrescribedVoltageChartLimits {
        .init(maximumTriplets: triplets, maximumRetainedBytes: retained, maximumWorkspaceBytes: workspace,
            precisionBits: 192, values: limits(),
            exact: .init(maximumRows: 16, maximumColumns: 16, maximumIntegerBits: 4096,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576),
            root: .init(maximumDimension: 16, maximumJacobianNonzeros: 64, maximumPreconditionerNonzeros: 64,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    private func originalDomain() throws -> NativeGlobalChargeDomain {
        try domain([0, -3, -3, -10], [2, 3, 3, 10])
    }
    private func slab(_ owner: borrowing PreparedNativeCircuit, middle: Double = 0.1875,
        timeRange: Bool = false) async throws -> NativePrescribedVoltageValues {
        let d = try originalDomain()
        let actual = timeRange ? try NativeGlobalChargeDomain(lower: d.lower, upper: d.upper,
            lowerContext: context(0), upperContext: context(1)) : d
        return try await values(owner, actual, [source(u: 0.25...0.5)],
            z: [E(center: .init(high: middle), radius: 0.125), E(center: .init(high: 0.75), radius: 0.5)])
    }
    private func certify(_ owner: borrowing PreparedNativeCircuit, _ v: NativePrescribedVoltageValues,
        b: [Int] = [1], initial: E? = nil, middle: Double = 0.1875,
        inverseValues: [Double] = [1, 4], ceiling: NativePrescribedVoltageChartLimits? = nil,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageInitialRoot {
        try await owner.certifyPrescribedVoltageInitialRoot(values: v, algebraicRows: b,
            dynamicInitialCoordinates: [try initial ?? E(center: .init(high: middle), radius: 0.0625)],
            center: [.init(high: middle), .init(high: 0.75)],
            inverse: SparseStructure(dimension: 2, rowPointers: [0, 1, 2], columnIndices: [0, 1]),
            inverseValues: inverseValues, capture: nil, range: nil,
            limits: ceiling ?? chartLimits(), cancellation: cancellation)
    }

    @Test func isolatedDynamicCoordinateDefinesInitialChargeWithoutADCOrChargeInput() async throws {
        let owner = try fixture()
        let firstValues = try await slab(owner)
        let first = try await certify(owner, firstValues)
        let secondValues = try await slab(owner, middle: 0.6875)
        let second = try await certify(owner, secondValues, middle: 0.6875)
        #expect(first.dimension == 2 && first.chargeCoordinateCount == 1 && first.algebraicCoordinateCount == 1)
        #expect(try first.chargeReducedRow(at: 0) == 0)
        #expect(try first.algebraicReducedRow(at: 0) == 1)
        contains(try first.image(at: 0), 0.125); contains(try first.image(at: 0), 0.25)
        contains(try first.image(at: 1), 0.5); contains(try first.image(at: 1), 1)
        contains(try first.initialCharge(at: 0), 0.25); contains(try first.initialCharge(at: 0), 0.5)
        contains(try second.initialCharge(at: 0), 1.25); contains(try second.initialCharge(at: 0), 1.5)
        let a = try first.initialCharge(at: 0), b = try second.initialCharge(at: 0)
        #expect(a.center.bounds.upper + a.radius < b.center.bounds.lower - b.radius)
        let payload = try first.initialPayload(record: owner.record)
        #expect(payload.jacobian.rowPointers == [0, 1, 2] && payload.jacobian.columnIndices == [0, 1])
        contains(payload.jacobianValues[0], 1); contains(payload.jacobianValues[1], 0.25)
        #expect(payload.checkedQValues !== payload.values && payload.checkedQValues !== payload.centerValues)
        #expect(payload.checkedQValues.dimension == owner.plan.topology.dimension)
    }

    @Test func initialCoordinateAndSelectorProposalsDoNotGrantRootAuthority() async throws {
        let owner = try fixture(), v = try await slab(owner)
        do { _ = try await certify(owner, v, b: [0]); Issue.record("Nonzero charge row was treated as an algebraic initial constraint") }
        catch NativePrescribedVoltageChartFailure.unprovedNullRow {}
        for rows in [[-1], [2], [1, 1], [1, 0]] {
            do { _ = try await certify(owner, v, b: rows); Issue.record("Invalid B rows admitted") }
            catch NativePrescribedVoltageChartFailure.invalidInput {}
        }
        do { _ = try await certify(owner, v, initial: scalar(8)); Issue.record("Outside initial coordinate admitted") }
        catch ValidatedParametricRoot.Failure.uncertified {}
        do { _ = try await certify(owner, v, inverseValues: [0, 4]); Issue.record("Singular initial preconditioner admitted") }
        catch ValidatedParametricRoot.Failure.uncertified {}
        let timeSlab = try await slab(owner, timeRange: true)
        do { _ = try await certify(owner, timeSlab); Issue.record("A non-singleton initial time was admitted") }
        catch NativePrescribedVoltageChartFailure.invalidBinding {}
        let d = try originalDomain()
        let high = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        let low = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0x1p-60)
        let paired = try NativeGlobalChargeDomain(lower: d.lower, upper: d.upper, lowerContext: high, upperContext: low)
        let pairedValues = try await values(owner, paired, [source(u: 0.25...0.5)],
            z: [E(center: .init(high: 0.1875), radius: 0.125), E(center: .init(high: 0.75), radius: 0.5)])
        do { _ = try await certify(owner, pairedValues); Issue.record("Distinct compensated initial time pair admitted") }
        catch NativePrescribedVoltageChartFailure.invalidBinding {}
    }

    @Test func sameControlCoexistenceCumulativeWorkAndCopiedResultRetention() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources), other = try fixture()
            let v = try await slab(owner), live = resources.live, temporary = resources.temporary
            do { _ = try await certify(other, v); Issue.record("Foreign initial Values admitted") }
            catch NativePrescribedVoltageChartFailure.wrongOwner {}
            for limit in [chartLimits(triplets: 0), chartLimits(retained: 1), chartLimits(workspace: 1)] {
                do { _ = try await certify(owner, v, ceiling: limit); Issue.record("Initial root capacity ignored") }
                catch NativePrescribedVoltageChartFailure.capacityExceeded {}
                catch NativeGlobalChargeFailure.capacityExceeded {}
                #expect(resources.live == live && resources.temporary == temporary)
            }
            resources.arm(storage: true)
            do { _ = try await certify(owner, v); Issue.record("Storage admission refused but result published") }
            catch Refusal.storage {}
            resources.arm()
            let token = CancellationToken(); token.cancel()
            do { _ = try await certify(owner, v, cancellation: token); Issue.record("Cancelled initial root published") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            let before = resources.units
            do { let root = try await certify(owner, v); contains(try root.initialCharge(at: 0), 0.375) }
            let cost = resources.units - before
            #expect(cost > 1 && resources.live == live && resources.temporary == temporary)
            try resources.charge(.retainedElements, units: 17)
            resources.arm(work: cost - 1)
            do { _ = try await certify(owner, v); Issue.record("Second operation reset the shared remaining work") }
            catch Refusal.work {}
            resources.arm()
            #expect(resources.live == live && resources.temporary == temporary)
            var original: NativePrescribedVoltageInitialRoot? = try await certify(owner, v)
            var copy = original
            original = nil
            #expect(resources.live > live)
            try owner.close()
            contains(try #require(copy).image(at: 0), 0.1875)
            do { _ = try #require(copy).initialPayload(record: other.record); Issue.record("A copied root accepted another prepared owner") }
            catch NativePrescribedVoltageChartFailure.wrongOwner {}
            copy = nil
            #expect(resources.live == live && resources.temporary == temporary)
            #expect(resources.peak > live + temporary)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func checkedInitialBoxCannotEscapeTheOriginalFloatingDomain() async throws {
        let p = Node(id: 1), n = Node(id: 2), owner = try prepare([
            voltage(positive: n, negative: p),
            .init(name: "Cfree", typeName: "capacitor", nodes: [p, .ground], parameters: ["c": .real(2)])],
            nodes: [.ground, p, n])
        let input = source(u: 0...0, scale: 1, one: 0, left: 0, right: 0)
        let shifted = NativePrescribedVoltageSource(deviceIndex: input.deviceIndex, zeroVoltage: -1e10,
            oneVoltage: input.oneVoltage, timeOrigin: 0, timeScale: 1,
            normalized: input.normalized, leftSlope: input.leftSlope, rightSlope: input.rightSlope)
        let proposal = try E(center: .init(high: 1e10), radius: 1)
        let tight = try domain([1e10 - 2, -1.0000001, 5], [1e10 + 2, 1.0000001, 6])
        let v = try await values(owner, tight, [shifted], z: [proposal])
        do {
            _ = try await owner.certifyPrescribedVoltageInitialRoot(values: v, algebraicRows: [],
                dynamicInitialCoordinates: [scalar(1e10)], center: [.init(high: 1e10)],
                inverse: SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0]),
                inverseValues: [1], capture: nil, range: nil, limits: chartLimits(), cancellation: .init())
            Issue.record("Expanded initial root domain escaped original D")
        } catch NativePrescribedVoltageFailure.outsideOriginalDomain(let row) { #expect(row == 1) }
    }
}
