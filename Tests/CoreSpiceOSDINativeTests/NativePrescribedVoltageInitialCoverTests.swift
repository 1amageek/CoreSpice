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

@Suite("Finite native initial-domain covers", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageInitialCoverTests {
    typealias E = CompensatedEnclosure
    enum Refusal: Error { case work, storage }
    final class Resources: SPICESourceResourceAccounting {
        struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var refuseStorage = false; var work: UInt64? = nil; var units: UInt64 = 0; var peak: UInt64 = 0; var cancelOnReserve: CancellationToken? }
        let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var units: UInt64 { state.withLock { $0.units } }
        var peak: UInt64 { state.withLock { $0.peak } }
        func arm(storage: Bool = false, work: UInt64? = nil) { state.withLock { $0.refuseStorage = storage; $0.work = work } }
        func cancelNextReservation(_ token: CancellationToken) { state.withLock { $0.cancelOnReserve = token } }
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
            let cancel = state.withLock { value in let token = value.cancelOnReserve; value.cancelOnReserve = nil; return token }
            cancel?.cancel()
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { value in
                if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
            }}
        }
    }
    func scalar(_ x: Double) throws -> E { try .init(center: .init(high: x)) }
    func context(_ time: Double = 0.25) throws -> OSDIPrecisionContext { try .init(mode: .transient, timeHigh: time, timeLow: 0) }
    func domain(_ lo: [Double], _ hi: [Double]) throws -> NativeGlobalChargeDomain {
        try .init(lower: lo.map { try .init(high: $0) }, upper: hi.map { try .init(high: $0) },
            lowerContext: context(), upperContext: context())
    }
    func limits(retained: Int = 131_072) -> NativePrescribedVoltageLimits {
        .init(maximumNativeTerms: 16_384, maximumRetainedBytes: retained, maximumWorkspaceBytes: 1_048_576,
            precisionBits: 192, reductionLimits: .init(maximumAxes: 16_384, maximumSources: 8,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    func source(_ index: Int = 0, u: ClosedRange<Double> = 0.5...0.5, scale: Double = 2, one: Double = 2, left: Double = 1, right: Double = 1) -> NativePrescribedVoltageSource {
        .init(deviceIndex: index, zeroVoltage: 0, oneVoltage: one, timeOrigin: 0, timeScale: scale,
            normalized: u, leftSlope: left...left, rightSlope: right...right)
    }
    func voltage(_ name: String = "V1", positive: Node, negative: Node, branch: Branch = .init(id: 0),
        parameters: [String: ParameterValue] = ["v": .real(0)]) -> Instance {
        .init(name: name, typeName: "vsource", nodes: [positive, negative], parameters: parameters, ownedBranches: [branch])
    }
    func prepare(_ instances: [Instance], nodes: [Node], branches: [Branch] = [.init(id: 0)],
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
    func values(_ owner: borrowing PreparedNativeCircuit, _ d: NativeGlobalChargeDomain,
        _ sources: [NativePrescribedVoltageSource], z: [E] = [], retained: Int = 131_072,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageValues {
        try await owner.enclosePrescribedVoltageValues(originalDomain: d, sources: sources, reducedCoordinates: z,
            capture: nil, limits: limits(retained: retained), cancellation: cancellation)
    }
    func contains(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = value.center.bounds
        let lo = value.radius == 0 ? bounds.lower : (bounds.lower - value.radius).nextDown
        let hi = value.radius == 0 ? bounds.upper : (bounds.upper + value.radius).nextUp
        #expect(lo <= expected && expected <= hi, sourceLocation: sourceLocation)
    }

    func fixture(resources: Resources = .init()) throws -> PreparedNativeCircuit {
        let p = Node(id: 1), d = Node(id: 2), x = Node(id: 3)
        return try prepare([voltage(positive: p, negative: .ground),
            .init(name: "Cd", typeName: "capacitor", nodes: [d, .ground], parameters: ["c": .real(2)]),
            .init(name: "Rx", typeName: "resistor", nodes: [x, p], parameters: ["r": .real(4)])],
            nodes: [.ground, p, d, x], resources: resources)
    }
    func chartLimits(triplets: Int = 64, retained: Int = 1_048_576, workspace: Int = 1_048_576) -> NativePrescribedVoltageChartLimits {
        .init(maximumTriplets: triplets, maximumRetainedBytes: retained, maximumWorkspaceBytes: workspace,
            precisionBits: 192, values: limits(),
            exact: .init(maximumRows: 16, maximumColumns: 16, maximumIntegerBits: 4096,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576),
            root: .init(maximumDimension: 16, maximumJacobianNonzeros: 64, maximumPreconditionerNonzeros: 64,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    func originalDomain() throws -> NativeGlobalChargeDomain {
        try domain([0, -3, -3, -10], [2, 3, 3, 10])
    }
    func slab(_ owner: borrowing PreparedNativeCircuit, middle: Double = 0.1875,
        timeRange: Bool = false) async throws -> NativePrescribedVoltageValues {
        let d = try originalDomain()
        let actual = timeRange ? try NativeGlobalChargeDomain(lower: d.lower, upper: d.upper,
            lowerContext: context(0), upperContext: context(1)) : d
        return try await values(owner, actual, [source(u: 0.25...0.5)],
            z: [E(center: .init(high: middle), radius: 0.125), E(center: .init(high: 0.75), radius: 0.5)])
    }
    func certify(_ owner: borrowing PreparedNativeCircuit, _ v: NativePrescribedVoltageValues,
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

    func coverLimits(nodes: Int = 64, depth: Int = 16, workspace: Int = 1_048_576, retained: Int = 1_048_576) -> NativePrescribedVoltageInitialCoverLimits {
        .init(maximumAxes: 16, maximumNodes: nodes, maximumDepth: depth, maximumWorkspaceBytes: workspace, maximumRetainedBytes: retained)
    }
    func endpoint(_ x: Double) throws -> CompensatedValue { try .init(high: x) }
    func plane(_ owner: borrowing PreparedNativeCircuit, _ v: NativePrescribedVoltageValues, b: [Int] = [1]) async throws -> NativePrescribedVoltageInitialStructure {
        try await owner.preparePrescribedVoltageInitialStructure(values: v, algebraicRows: b, capture: nil,
            limits: chartLimits(), cancellation: .init())
    }
    func check(_ owner: borrowing PreparedNativeCircuit, _ structure: NativePrescribedVoltageInitialStructure,
        lower: [Double] = [0.125,0.5], upper: [Double] = [0.25,1], u: [ClosedRange<Double>] = [0.25...0.5],
        nodes: [NativePrescribedVoltageInitialCoverProposal.Node], limit: NativePrescribedVoltageInitialCoverLimits? = nil,
        cancellation: CancellationToken = .init()) throws -> NativePrescribedVoltageInitialCover {
        try owner.checkPrescribedVoltageInitialCover(structure: structure,
            originalLower: lower.map { try endpoint($0) }, originalUpper: upper.map { try endpoint($0) },
            initialNormalized: u, proposal: .init(nodes: nodes), limits: limit ?? coverLimits(), cancellation: cancellation)
    }
    func wideRoot(_ owner: borrowing PreparedNativeCircuit) async throws -> NativePrescribedVoltageInitialRoot {
        let v = try await values(owner, originalDomain(), [source(u: 0.25...0.5)],
            z: [E(center: .init(high: 0.1875), radius: 0.25), E(center: .init(high: 0.75), radius: 1)])
        return try await certify(owner, v, initial: E(center: .init(high: 0.1875), radius: 0.09375))
    }
    @Test func allLeavesAndSharedParameterBoundariesAreChecked() async throws {
        let owner = try fixture(), v = try await slab(owner), s = try await plane(owner, v), root = try await wideRoot(owner)
        let result = try check(owner, s, nodes: [.split(axis: 2, at: endpoint(0.375), left: 1, right: 2), .included(root), .included(root)])
        #expect(result.isComplete && !result.isProvedEmpty && result.includedLeafCount == 2)
        #expect(try result.sourceRange(at: 0) == 0.25...0.5)
        #expect(try result.coordinateLower(at: 0) == endpoint(0.125))
        let pending = try check(owner, s, nodes: [.split(axis: 1, at: endpoint(0.75), left: 1, right: 2), .included(root), .unresolved])
        #expect(!pending.isComplete && pending.unresolvedLeafCount == 1)
        try owner.close()
    }
    @Test func strictActualResidualExcludesWithoutAnySuccessfulRoot() async throws {
        let owner = try fixture()
        let v = try await values(owner, originalDomain(), [source(u: 0.25...0.5)],
            z: [E(center: .init(high: 0.1875), radius: 0.25), E(center: .init(high: -1.5), radius: 0.75)])
        let s = try await plane(owner, v)
        let result = try check(owner, s, lower: [0.125,-2], upper: [0.25,-1], nodes: [.excluded(values: v, component: 1)])
        #expect(result.isComplete && result.isProvedEmpty && result.excludedLeafCount == 1)
        let residual = try #require(result.leaf(at: 0).residual)
        #expect(residual.center.bounds.upper + residual.radius < 0)
        do { _ = try await plane(owner, v, b: [0]); Issue.record("Nonzero Q row was accepted as a strong algebraic row") }
        catch NativePrescribedVoltageChartFailure.unprovedNullRow {}
        do { _ = try check(owner, s, nodes: [.excluded(values: v, component: 0)]); Issue.record("Derived dynamic initial identity was used to exclude") }
        catch NativePrescribedVoltageInitialCoverFailure.insufficientWitness {}
        try owner.close()
    }
    @Test func treeAndContainmentDirectionCannotHideUncoveredPoints() async throws {
        let owner = try fixture(), v = try await slab(owner), s = try await plane(owner, v), root = try await wideRoot(owner)
        let malformed: [[NativePrescribedVoltageInitialCoverProposal.Node]] = try [
            [.unresolved,.unresolved], [.split(axis: 0, at: endpoint(0.1875), left: 1, right: 1),.unresolved],
            [.split(axis: 0, at: endpoint(0.1875), left: 0, right: 1),.unresolved],
            [.split(axis: 0, at: endpoint(0.125), left: 1, right: 2),.unresolved,.unresolved],
            [.split(axis: 3, at: endpoint(0.5), left: 1, right: 2),.unresolved,.unresolved]]
        for nodes in malformed {
            do { _ = try check(owner, s, nodes: nodes); Issue.record("Malformed cover tree admitted") }
            catch NativePrescribedVoltageInitialCoverFailure.invalidInput {}
        }
        do { _ = try check(owner, s, lower: [-0.5,-1], upper: [0.5,2], nodes: [.included(root)]); Issue.record("Root box inside leaf was mistaken for leaf inside root") }
        catch NativePrescribedVoltageInitialCoverFailure.insufficientWitness {}
        do { _ = try check(owner, s, u: [0.25...0.4], nodes: [.unresolved]); Issue.record("Original source parameter domain narrowed") }
        catch NativePrescribedVoltageInitialCoverFailure.invalidBinding {}
        do { _ = try check(owner, s, nodes: [.excluded(values: v, component: 1)]); Issue.record("Residual interval containing zero excluded") }
        catch NativePrescribedVoltageInitialCoverFailure.insufficientWitness {}
        let differentPlane = try await plane(owner, v, b: [])
        do { _ = try check(owner, differentPlane, nodes: [.included(root)]); Issue.record("A different B/L plane was accepted") }
        catch NativePrescribedVoltageInitialCoverFailure.invalidBinding {}
        let original = try originalDomain(), time = try context(0.5)
        let shifted = try NativeGlobalChargeDomain(lower: original.lower, upper: original.upper, lowerContext: time, upperContext: time)
        let shiftedValues = try await values(owner, shifted, [source(u: 0.25...0.5)],
            z: [E(center: .init(high: 0.1875), radius: 0.125), E(center: .init(high: 0.75), radius: 0.5)])
        do { _ = try check(owner, s, nodes: [.excluded(values: shiftedValues, component: 1)]); Issue.record("A different initial source context was accepted") }
        catch NativePrescribedVoltageInitialCoverFailure.invalidBinding {}
        let changedRails = try await values(owner, original, [source(u: 0.25...0.5, one: 1)],
            z: [E(center: .init(high: 0.1875), radius: 0.125), E(center: .init(high: 0.75), radius: 0.5)])
        do { _ = try check(owner, s, nodes: [.excluded(values: changedRails, component: 1)]); Issue.record("Different source rails were accepted") }
        catch NativePrescribedVoltageInitialCoverFailure.invalidBinding {}
        try owner.close()
    }
    @Test func originalControlRefusalsAndFinalCopyReleaseRemainObservable() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources), v = try await slab(owner), s = try await plane(owner, v)
            let baseline = resources.live, temporary = resources.temporary, other = try fixture()
            do { _ = try check(other, s, nodes: [.unresolved]); Issue.record("Foreign owner accepted") }
            catch NativePrescribedVoltageInitialCoverFailure.wrongOwner {}
            try other.close()
            for limit in [coverLimits(nodes: 0), coverLimits(workspace: 1), coverLimits(retained: 1)] {
                do { _ = try check(owner, s, nodes: [.unresolved], limit: limit); Issue.record("Capacity ignored") }
                catch NativePrescribedVoltageInitialCoverFailure.invalidInput {}
                catch NativePrescribedVoltageInitialCoverFailure.capacityExceeded {}
            }
            resources.arm(storage: true)
            do { _ = try check(owner, s, nodes: [.unresolved]); Issue.record("Storage failure hidden") }
            catch Refusal.storage {}
            resources.arm(work: 0)
            do { _ = try check(owner, s, nodes: [.unresolved]); Issue.record("Shared work reset") }
            catch Refusal.work {}
            resources.arm()
            let token = CancellationToken(); token.cancel()
            do { _ = try check(owner, s, nodes: [.unresolved], cancellation: token); Issue.record("Cancellation hidden") }
            catch NativePrescribedVoltageInitialCoverFailure.cancelled {}
            #expect(resources.live == baseline && resources.temporary == temporary)
            let callbackToken = CancellationToken(); resources.cancelNextReservation(callbackToken)
            do { _ = try check(owner, s, nodes: [.unresolved], cancellation: callbackToken); Issue.record("Post-reservation cancellation was hidden") }
            catch NativePrescribedVoltageInitialCoverFailure.cancelled {}
            #expect(resources.live == baseline && resources.temporary == temporary)
            var original: NativePrescribedVoltageInitialCover? = try check(owner, s, nodes: [.unresolved])
            var copy = original; original = nil
            #expect(resources.live > baseline)
            try owner.close()
            #expect(try #require(copy).unresolvedLeafCount == 1)
            copy = nil
            #expect(resources.live == baseline && resources.temporary == temporary)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
