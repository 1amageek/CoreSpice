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

@Suite("Actual native prescribed charge rates and current reconstruction", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageReconstructionTests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var refuseStorage = false; var work: UInt64? = nil }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        func arm(storage: Bool = false, work: UInt64? = nil) { state.withLock { $0.refuseStorage = storage; $0.work = work } }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                guard let remaining = value.work else { return }
                guard units <= remaining else { throw Refusal.work }; value.work = remaining - units
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try state.withLock { value in
                guard !value.refuseStorage else { throw Refusal.storage }
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
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
        .init(maximumNativeTerms: 128, maximumRetainedBytes: retained, maximumWorkspaceBytes: 1_048_576,
            precisionBits: 192, reductionLimits: .init(maximumAxes: 16, maximumSources: 8,
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
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 16,
            maximumWorkUnits: 1_000_000, maximumBreakpoints: 10)
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: 16, maximumMatrixDimension: 16, maximumAllocationBytes: 16_777_216)
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

    private func reconstruct(_ owner: borrowing PreparedNativeCircuit, _ values: NativePrescribedVoltageValues,
        left: [E] = [], right: [E] = [], retained: Int = 131_072,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageReconstruction {
        try await owner.reconstructPrescribedVoltageCurrents(values: values, leftReducedRates: left,
            rightReducedRates: right, range: nil,
            limits: .init(maximumRetainedBytes: retained, maximumWorkspaceBytes: 1_048_576, precisionBits: 192),
            cancellation: cancellation)
    }
    private func parallel(_ p: Node, reversed: Bool = false, resources: Resources = .init()) throws -> PreparedNativeCircuit {
        try prepare([voltage(positive: reversed ? .ground : p, negative: reversed ? p : .ground),
            .init(name: "C1", typeName: "capacitor", nodes: [p, .ground], parameters: ["c": .real(2)]),
            .init(name: "R1", typeName: "resistor", nodes: [p, .ground], parameters: ["r": .real(4)])],
            nodes: [.ground, p], resources: resources)
    }

    @Test(arguments: [false, true]) func actualChargeChainRuleKeepsBothSidesAndTimeScale(reversed: Bool) async throws {
        let p = Node(id: 1), owner = try parallel(p, reversed: reversed)
        let v = try await values(owner, domain([-2, -8], [3, -1]),
            [source(u: 0.25...0.75, left: 1, right: 3)])
        let result = try await reconstruct(owner, v)
        for side in [NativePrescribedVoltageReconstruction.Side.left, .right] {
            let slope = side == .left ? 1.0 : 3.0
            contains(try result.prescribedChargeRate(at: 0, side: side), (reversed ? -2 : 2) * slope)
            contains(try result.stateChargeRate(at: 0, side: side), 0)
            // phi(.5)=1 and F0=1/4. Omitting the actual input charge rate would give -.25.
            contains(try result.coordinate(at: 1, side: side), -0.25 - 2 * slope)
            contains(try result.originalResidual(at: 1, side: side), 0)
        }
        let point = try await values(owner, domain([-2, -8], [3, -1]), [source(left: 1, right: 3)])
        let pointResult = try await reconstruct(owner, point)
        contains(try pointResult.coordinate(at: 1, side: .left), -2.25)
        contains(try pointResult.coordinate(at: 1, side: .right), -6.25)
        #expect(try pointResult.coordinate(at: 1, side: .left).absoluteUpperBound > 2)
    }

    @Test func allSelectedCurrentsMustRemainInsideOriginalDomain() async throws {
        let p = Node(id: 1), owner = try parallel(p)
        let v = try await values(owner, domain([-2, 5], [3, 6]), [source()])
        await #expect(throws: NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(row: 1, side: .left)) {
            try await reconstruct(owner, v)
        }
        let rightOnly = try await values(owner, domain([-2, -3], [3, -2]), [source(left: 1, right: 3)])
        await #expect(throws: NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(row: 1, side: .right)) {
            try await reconstruct(owner, rightOnly)
        }
    }

    @Test func twoSourceTreeReconstructsEveryOrientedCurrentAndOriginalRow() async throws {
        let p = Node(id: 1), n = Node(id: 2)
        let owner = try prepare([voltage(positive: p, negative: .ground),
            voltage("V2", positive: p, negative: n, branch: .init(id: 1)),
            .init(name: "C1", typeName: "capacitor", nodes: [p, .ground], parameters: ["c": .real(2)]),
            .init(name: "C2", typeName: "capacitor", nodes: [n, .ground], parameters: ["c": .real(3)]),
            .init(name: "R1", typeName: "resistor", nodes: [p, .ground], parameters: ["r": .real(4)])],
            nodes: [.ground, p, n], branches: [.init(id: 0), .init(id: 1)])
        let v = try await values(owner, domain([-2, -2, -5, 0], [2, 2, -3, 3]), [source(), source(1, one: 1)])
        let result = try await reconstruct(owner, v)
        for side in [NativePrescribedVoltageReconstruction.Side.left, .right] {
            contains(try result.coordinate(at: 2, side: side), -3.75)
            contains(try result.coordinate(at: 3, side: side), 1.5)
            for row in 0..<4 { contains(try result.originalResidual(at: row, side: side), 0) }
        }
    }

    @Test func floatingStateRateAndUnresolvedSupernodeResidualAreRetained() async throws {
        let p = Node(id: 1), n = Node(id: 2)
        let owner = try prepare([voltage(positive: p, negative: n),
            .init(name: "C1", typeName: "capacitor", nodes: [p, n], parameters: ["c": .real(2)]),
            .init(name: "C2", typeName: "capacitor", nodes: [n, .ground], parameters: ["c": .real(3)]),
            .init(name: "R1", typeName: "resistor", nodes: [p, n], parameters: ["r": .real(4)])], nodes: [.ground, p, n])
        let v = try await values(owner, domain([-2, -2, -5], [2, 2, -2]), [source()], z: [scalar(0.5)])
        let result = try await reconstruct(owner, v, left: [scalar(0.5)], right: [scalar(0.5)])
        contains(try result.stateChargeRate(at: 1, side: .left), 1.5)
        contains(try result.prescribedChargeRate(at: 1, side: .left), -5)
        contains(try result.coordinate(at: 2, side: .left), -3.75)
        contains(try result.reducedResidual(at: 0, side: .left), -1.5)
        #expect(try result.reducedResidual(at: 0, side: .left).absoluteUpperBound >= 1.5)
    }

    @Test func wrongOwnerShapeCapacityCancellationAndLeaseFailuresNeverPublish() async throws {
        let p = Node(id: 1), resources = Resources()
        do {
            let owner = try parallel(p, resources: resources)
            let v = try await values(owner, domain([-2, -3], [3, -2]), [source()])
            let other = try parallel(p)
            await #expect(throws: NativePrescribedVoltageReconstructionFailure.wrongOwner) { try await reconstruct(other, v) }
            await #expect(throws: NativePrescribedVoltageReconstructionFailure.invalidInput) {
                try await reconstruct(owner, v, left: [scalar(0)])
            }
            let baseline = resources.live, temporaryBaseline = resources.temporary
            // Values retains the original Plan/Lift leases in the shared temporary category.
            #expect(temporaryBaseline > 0)
            await #expect(throws: NativePrescribedVoltageReconstructionFailure.capacityExceeded) {
                try await reconstruct(owner, v, retained: 1)
            }
            resources.arm(work: 0)
            await #expect(throws: Refusal.work) { try await reconstruct(owner, v) }
            resources.arm(storage: true)
            await #expect(throws: Refusal.storage) { try await reconstruct(owner, v) }
            resources.arm()
            let cancelled = CancellationToken(); cancelled.cancel()
            do { _ = try await reconstruct(owner, v, cancellation: cancelled); Issue.record("Cancelled reconstruction published") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            #expect(resources.live == baseline && resources.temporary == temporaryBaseline)
            do {
                let result = try await reconstruct(owner, v)
                let copy = result
                withExtendedLifetime(copy) { #expect(resources.live > baseline) }
            }
            #expect(resources.live == baseline && resources.temporary == temporaryBaseline)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
