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

@Suite("Actual native reduced mass and drift", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageMassTests {
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

    private func mass(_ owner: borrowing PreparedNativeCircuit, _ values: NativePrescribedVoltageValues,
        triplets: Int = 16_384, retained: Int = 4_194_304, workspace: Int = 4_194_304,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageMass {
        try await owner.assemblePrescribedVoltageMass(values: values, range: nil,
            limits: .init(maximumTriplets: triplets, maximumRetainedBytes: retained,
                maximumWorkspaceBytes: workspace, precisionBits: 192), cancellation: cancellation)
    }
    private func regularityLimits(_ n: Int) -> ValidatedMatrixRegularity.Limits {
        .init(maximumDimension: max(1, n), maximumMatrixNonzeros: max(1, n * 4),
            maximumInverseNonzeros: max(1, n * 4), maximumWorkspaceBytes: 1_048_576)
    }
    private func floating(resources: Resources = .init()) throws -> PreparedNativeCircuit {
        let p = Node(id: 1), n = Node(id: 2)
        return try prepare([voltage(positive: p, negative: n),
            .init(name: "Cbetween", typeName: "capacitor", nodes: [p, n], parameters: ["c": .real(2)]),
            .init(name: "Cground", typeName: "capacitor", nodes: [n, .ground], parameters: ["c": .real(3)]),
            .init(name: "Rbetween", typeName: "resistor", nodes: [p, n], parameters: ["r": .real(4)])], nodes: [.ground, p, n], resources: resources)
    }

    @Test func exactFloatingProjectionCoalescesMassAndBothDriftsBeforeCertification() async throws {
        let owner = try floating()
        let v = try await values(owner, domain([-2, -2, -10], [2, 2, 10]), [source(left: 1, right: 3)], z: [scalar(0.5)])
        let result = try await mass(owner, v)
        result.withMatrix { n, rows, columns, coefficients in
            #expect(n == 1 && rows.count == 2 && rows[0] == 0 && rows[1] == 1 && columns[0] == 0)
            contains(coefficients[0], 3)
        }
        contains(try result.drift(at: 0, side: .left), -3)
        contains(try result.drift(at: 0, side: .right), -9)
        let inverse = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0])
        let r = [1.0 / 3.0]
        let fact = try result.certifyRegularity(inverse: inverse, inverseValues: r.span,
            limits: regularityLimits(1), cancellation: .init())
        #expect(fact.dimension == 1 && fact.normUpperBound < 1e-10)
        let bad = [1.0]
        #expect(throws: ValidatedMatrixRegularity.Failure.uncertified) {
            try result.certifyRegularity(inverse: inverse, inverseValues: bad.span, limits: regularityLimits(1), cancellation: .init())
        }
    }

    @Test func emptyReductionDoesNotFabricateARegularityFact() async throws {
        let p = Node(id: 1), owner = try prepare([voltage(positive: p, negative: .ground)], nodes: [.ground, p])
        let v = try await values(owner, domain([-2, -1], [3, 1]), [source()])
        let result = try await mass(owner, v, triplets: 0)
        result.withMatrix { n, rows, columns, coefficients in
            #expect(n == 0 && rows.count == 1 && rows[0] == 0 && columns.isEmpty && coefficients.isEmpty)
        }
        let empty = try SparseStructure(dimension: 0, rowPointers: [0], columnIndices: [])
        let r: [Double] = []
        #expect(throws: NativePrescribedVoltageMassFailure.emptyMass) {
            try result.certifyRegularity(inverse: empty, inverseValues: r.span, limits: regularityLimits(0), cancellation: .init())
        }
    }

    @Test func capacityOwnerCancellationAndFinalCertificateLifetimeShareOriginalControl() async throws {
        #expect(throws: NativePrescribedVoltageFailure.capacityExceeded) {
            try NativePrescribedVoltageMassAssembly.workspaceByteCount(capacity: Int.max, dimension: 1,
                reducedCount: 1, sourceCount: 1, projectionBytes: 0)
        }
        let resources = Resources()
        do {
            let owner = try floating(resources: resources)
            let v = try await values(owner, domain([-2, -2, -10], [2, 2, 10]), [source()], z: [scalar(0.5)])
            let other = try floating()
            await #expect(throws: NativePrescribedVoltageMassFailure.wrongOwner) { try await mass(other, v) }
            let live = resources.live, temporary = resources.temporary
            await #expect(throws: NativePrescribedVoltageMassFailure.capacityExceeded) { try await mass(owner, v, triplets: 0) }
            await #expect(throws: NativePrescribedVoltageMassFailure.capacityExceeded) { try await mass(owner, v, retained: 1) }
            await #expect(throws: NativePrescribedVoltageMassFailure.capacityExceeded) { try await mass(owner, v, workspace: 1) }
            resources.arm(work: 0)
            await #expect(throws: Refusal.work) { try await mass(owner, v) }
            resources.arm(storage: true)
            await #expect(throws: Refusal.storage) { try await mass(owner, v) }
            resources.arm()
            let cancelled = CancellationToken(); cancelled.cancel()
            do { _ = try await mass(owner, v, cancellation: cancelled); Issue.record("Cancelled mass published") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            #expect(resources.live == live && resources.temporary == temporary)
            var certificate: NativePrescribedVoltageMass.Regularity?
            do {
                let result = try await mass(owner, v)
                let inverse = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0]), r = [1.0 / 3.0]
                certificate = try result.certifyRegularity(inverse: inverse, inverseValues: r.span,
                    limits: regularityLimits(1), cancellation: .init())
            }
            withExtendedLifetime(certificate) { #expect(resources.live > live && resources.temporary == temporary) }
            certificate = nil
            #expect(resources.live == live && resources.temporary == temporary)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func sparseFiveHundredTwelveAxisCircuitUsesSparseBuffersAndRefunds() async throws {
        let count = 512, resources = Resources()
        do {
            let clamp = Node(id: 1), free = (0..<count).map { Node(id: $0 + 2) }
            var instances = [voltage(positive: clamp, negative: .ground)]
            for index in 0..<count {
                instances.append(.init(name: "C" + String(index), typeName: "capacitor", nodes: [free[index], .ground], parameters: ["c": .real(2)]))
            }
            let owner = try prepare(instances, nodes: [.ground, clamp] + free, resources: resources)
            let n = owner.plan.topology.dimension
            let d = try domain([Double](repeating: -2, count: n), [Double](repeating: 3, count: n))
            let v = try await values(owner, d, [source()], z: [E](repeating: scalar(0.5), count: count), retained: 4_194_304)
            let managed = try NativePrescribedVoltageMassAssembly.workspaceByteCount(capacity: count,
                dimension: n, reducedCount: count, sourceCount: 1, projectionBytes: 0)
            #expect(managed.peak < count * 1024)
            let before = resources.units
            let result = try await mass(owner, v, triplets: count)
            result.withMatrix { dimension, rows, columns, coefficients in
                #expect(dimension == count && columns.count == count && rows.count == count + 1)
                for i in 0..<count { #expect(rows[i] == i && columns[i] == i); contains(coefficients[i], 2) }
            }
            let inverse = try SparseStructure(dimension: count, rowPointers: Array(0...count), columnIndices: Array(0..<count))
            let r = [Double](repeating: 0.5, count: count)
            let fact = try result.certifyRegularity(inverse: inverse, inverseValues: r.span,
                limits: regularityLimits(count), cancellation: .init())
            #expect(fact.dimension == count && fact.normUpperBound < 1e-10)
            print("Native mass sparse n=512 cumulativeWorkDelta=\(resources.units - before) peakManagedBytes=\(resources.peak)")
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
