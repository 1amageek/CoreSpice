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

@Suite("Actual native coordinate charge chart", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageChartTests {
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
            lowerContext: context(0), upperContext: context(1))
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
    private func slab(_ owner: borrowing PreparedNativeCircuit) async throws -> NativePrescribedVoltageValues {
        try await values(owner, originalDomain(), [source(u: 0.25...0.5)],
            z: [E(center: .zero, radius: 1), E(center: .init(high: 0.5), radius: 1.5)])
    }
    private func certify(_ owner: borrowing PreparedNativeCircuit, _ v: NativePrescribedVoltageValues,
        b: [Int] = [1], q: E? = nil, limits: NativePrescribedVoltageChartLimits? = nil,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageChart {
        let inverse = try SparseStructure(dimension: 2, rowPointers: [0, 1, 2], columnIndices: [0, 1])
        return try await owner.certifyPrescribedVoltageChart(values: v, algebraicRows: b,
            chargeParameters: [try q ?? E(center: .init(high: 0.375), radius: 0.125)],
            center: [.init(high: 0.25), .init(high: 0.75)], inverse: inverse, inverseValues: [0.5, 4],
            capture: nil, range: nil, limits: limits ?? chartLimits(), cancellation: cancellation)
    }

    @Test func singularMassStillAdmitsTheMixedCoordinateChargeChart() async throws {
        let owner = try fixture(), v = try await slab(owner)
        let chart = try await certify(owner, v)
        #expect(chart.dimension == 2 && chart.chargeCoordinateCount == 1 && chart.algebraicCoordinateCount == 1)
        #expect(chart.sourceInputCount == 0 && chart.normUpperBound < 1e-10)
        let dynamic = try chart.chargeReducedRow(at: 0), algebraic = try chart.algebraicReducedRow(at: 0)
        #expect(dynamic == 0 && algebraic == 1)
        contains(try chart.image(at: 0), 0.125); contains(try chart.image(at: 0), 0.25)
        contains(try chart.image(at: 1), 0.5); contains(try chart.image(at: 1), 1)
        // This accepted chart has M=diag(2,0), while J=diag(2,.25).
        let mass = try await owner.assemblePrescribedVoltageMass(values: v, range: nil,
            limits: .init(maximumTriplets: 16, maximumRetainedBytes: 1_048_576,
                maximumWorkspaceBytes: 1_048_576, precisionBits: 192), cancellation: .init())
        mass.withMatrix { dimension, rows, columns, coefficients in
            #expect(dimension == 2 && rows.count == 3 && rows[2] == 1 && columns.count == 1)
            contains(coefficients[0], 2)
        }
    }

    @Test func aDynamicChargeRowCannotBeAssertedAlgebraic() async throws {
        let owner = try fixture(), v = try await slab(owner)
        do { _ = try await certify(owner, v, b: [0]); Issue.record("A nonzero actual native charge row was certified null") }
        catch NativePrescribedVoltageChartFailure.unprovedNullRow {}
        for rows in [[-1], [2], [1, 1], [1, 0]] {
            do { _ = try await certify(owner, v, b: rows); Issue.record("Invalid selector rows were admitted") }
            catch NativePrescribedVoltageChartFailure.invalidInput {}
        }
    }

    @Test func aChargeParameterBoxOutsideTheChartCannotPublishARoot() async throws {
        let owner = try fixture(), v = try await slab(owner)
        do { _ = try await certify(owner, v, q: scalar(8)); Issue.record("An outside charge-parameter root was certified") }
        catch ValidatedParametricRoot.Failure.uncertified {}
    }

    @Test func ownershipCapacityCancellationAndFinalChartLeaseUseTheOriginalControl() async throws {
        let resources = Resources()
        do {
            let owner = try fixture(resources: resources), other = try fixture()
            let v = try await slab(owner), live = resources.live, temporary = resources.temporary
            do { _ = try await certify(other, v); Issue.record("A chart accepted Values from another owner") }
            catch NativePrescribedVoltageChartFailure.wrongOwner {}
            for ceiling in [chartLimits(triplets: 0), chartLimits(retained: 1), chartLimits(workspace: 1)] {
                do { _ = try await certify(owner, v, limits: ceiling); Issue.record("Chart capacity was ignored") }
                catch NativePrescribedVoltageChartFailure.capacityExceeded {}
                catch NativeGlobalChargeFailure.capacityExceeded {}
                #expect(resources.live == live && resources.temporary == temporary)
            }
            resources.arm(work: 0)
            do { _ = try await certify(owner, v); Issue.record("Chart work cap was ignored") }
            catch Refusal.work {}
            resources.arm(storage: true)
            do { _ = try await certify(owner, v); Issue.record("Chart storage refusal was ignored") }
            catch Refusal.storage {}
            resources.arm()
            let cancellation = CancellationToken(); cancellation.cancel()
            do { _ = try await certify(owner, v, cancellation: cancellation); Issue.record("Cancelled chart was published") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            #expect(resources.live == live && resources.temporary == temporary)
            var retained: NativePrescribedVoltageChart? = try await certify(owner, v)
            try owner.close()
            do { let observed = try #require(retained); contains(try observed.image(at: 0), 0.25) }
            #expect(resources.live > live)
            retained = nil
            #expect(resources.live == live && resources.temporary == temporary)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
    @Test func outwardRootBoxMustRemainInsideTheOriginalFloatingDomain() async throws {
        let p = Node(id: 1), n = Node(id: 2), resources = Resources()
        do {
            let owner = try prepare([voltage(positive: n, negative: p),
                .init(name: "Cfree", typeName: "capacitor", nodes: [p, .ground], parameters: ["c": .real(2)])],
                nodes: [.ground, p, n], resources: resources)
            let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
            let nRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(n)])
            #expect(pRow == 0 && nRow == 1)
            let input = NativePrescribedVoltageSource(deviceIndex: 0, zeroVoltage: -1e10, oneVoltage: 0,
                timeOrigin: 0, timeScale: 1, normalized: 0...0, leftSlope: 0...0, rightSlope: 0...0)
            let proposal = try E(center: .init(high: 1e10), radius: 1)
            let inverse = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0])
            func attempt(_ owner: borrowing PreparedNativeCircuit, _ values: NativePrescribedVoltageValues) async throws -> NativePrescribedVoltageChart {
                try await owner.certifyPrescribedVoltageChart(values: values, algebraicRows: [],
                    chargeParameters: [scalar(2e10)], center: [.init(high: 1e10)], inverse: inverse,
                    inverseValues: [0.5], capture: nil, range: nil, limits: chartLimits(), cancellation: .init())
            }
            do {
                let tight = try domain([1e10 - 2, -1.0000001, 5], [1e10 + 2, 1.0000001, 6])
                let v = try await values(owner, tight, [input], z: [proposal])
                contains(try v.sourceVoltage(at: 0), -1e10)
                #expect(try v.coordinateLower(at: nRow).bounds.lower > -1.0000001)
                #expect(try v.coordinateUpper(at: nRow).bounds.upper < 1.0000001)
                do { _ = try await attempt(owner, v); Issue.record("Expanded floating root Z escaped original D but published a chart") }
                catch NativePrescribedVoltageFailure.outsideOriginalDomain(let row) { #expect(row == nRow) }
            }
            do {
                let padded = try domain([1e10 - 2, -2, 5], [1e10 + 2, 2, 6])
                let v = try await values(owner, padded, [input], z: [proposal])
                let chart = try await attempt(owner, v)
                #expect(chart.dimension == 1 && chart.normUpperBound < 1e-10)
                let image = try chart.image(at: 0)
                contains(image, 1e10)
                // The independent physical-coordinate roots are p=z=1e10 and n=z+phi=0.
                contains(try image.adding(scalar(-1e10)), 0)
            }
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

}
