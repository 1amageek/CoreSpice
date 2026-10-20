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

@Suite("Actual native prescribed F0/Q values", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageValuesTests {
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
    private func source(_ index: Int = 0, u: ClosedRange<Double> = 0.5...0.5, scale: Double = 2) -> NativePrescribedVoltageSource {
        .init(deviceIndex: index, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: scale,
            normalized: u, leftSlope: 1...1, rightSlope: 1...1)
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
    private func check(_ owner: borrowing PreparedNativeCircuit, _ d: NativeGlobalChargeDomain,
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

    @Test func actualParallelCapacitorResistorAndSourceKeepFormalCurrentDomainExcludingZero() async throws {
        let p = Node(id: 1), resources = Resources()
        do {
            let owner = try prepare([voltage(positive: p, negative: .ground),
                .init(name: "C1", typeName: "capacitor", nodes: [p, .ground], parameters: ["c": .real(2)]),
                .init(name: "R1", typeName: "resistor", nodes: [p, .ground], parameters: ["r": .real(4)])],
                nodes: [.ground, p], resources: resources)
            let baseline = resources.live
            do {
                let result = try await check(owner, domain([-2, 5], [3, 6]), [source()])
                #expect(result.dimension == 2 && result.reducedCoordinateCount == 0 && result.selectedSourceCount == 1)
                #expect(try result.coordinateLower(at: 1) == CompensatedValue(high: 5))
                #expect(try result.coordinateUpper(at: 1) == CompensatedValue(high: 6))
                contains(try result.sourceVoltage(at: 0), 1)
                contains(try result.staticResidual(at: 0), 0.25); contains(try result.charge(at: 0), 2)
                #expect(try result.staticResidual(at: 1) == scalar(0))
                #expect(try result.charge(at: 1) == scalar(0))
                // Independent native analytic oracle: C * (delta/T) * normalizedSlope = 2 * (2/2) * 1.
                let analyticChargeRate = 2.0 * (2.0 / 2.0) * 1.0
                contains(try result.staticResidual(at: 0).adding(scalar(analyticChargeRate)).negated(), -2.25)
                contains(try result.staticResidual(at: 0).negated(), -0.25)
                #expect(resources.live > baseline)
            }
            #expect(resources.live == baseline && resources.temporary == 0)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test(arguments: [false, true]) func floatingAndReversedEdgesPreserveSignedValues(reversed: Bool) async throws {
        let p = Node(id: 1), n = Node(id: 2)
        let owner = try prepare([voltage(positive: reversed ? n : p, negative: reversed ? p : n),
            .init(name: "C1", typeName: "capacitor", nodes: [p, n], parameters: ["c": .real(2)]),
            .init(name: "R1", typeName: "resistor", nodes: [p, n], parameters: ["r": .real(4)])], nodes: [.ground, p, n])
        let result = try await check(owner, domain([-2, -2, 5], [2, 2, 6]), [source()], z: [scalar(0.25)])
        let sign = reversed ? -1.0 : 1.0
        contains(try result.charge(at: 0), 2 * sign); contains(try result.charge(at: 1), -2 * sign)
        contains(try result.staticResidual(at: 0), 0.25 * sign); contains(try result.staticResidual(at: 1), -0.25 * sign)
        #expect(try result.coordinateLower(at: 2) == CompensatedValue(high: 5))
        #expect(try result.coordinateUpper(at: 2) == CompensatedValue(high: 6))
    }

    @Test func actualUnselectedDCIsRetainedAndDynamicRequiresExplicitSelection() async throws {
        let p = Node(id: 1), n = Node(id: 2), second = Branch(id: 1)
        let selected = voltage(positive: p, negative: .ground)
        let dc = voltage("Vdc", positive: n, negative: .ground, branch: second, parameters: ["v": .real(2)])
        let owner = try prepare([selected, dc], nodes: [.ground, p, n], branches: [.init(id: 0), second])
        let result = try await check(owner, domain([-2, 1, 5, 6], [3, 3, 6, 8]), [source()], z: [scalar(2), scalar(7)])
        contains(try result.staticResidual(at: 1), 7); contains(try result.staticResidual(at: 3), 0)
        let pulse = voltage("Vpulse", positive: n, negative: .ground, branch: second,
            parameters: ["v1": .real(0), "v2": .real(1), "tr": .real(1), "tf": .real(1), "pw": .real(1), "per": .real(4)])
        let dynamic = try prepare([selected, pulse], nodes: [.ground, p, n], branches: [.init(id: 0), second])
        await #expect(throws: NativePrescribedVoltageFailure.unselectedDynamicSource(deviceIndex: 1)) {
            try await check(dynamic, domain([-2, -2, 5, 6], [3, 3, 6, 8]), [source()], z: [scalar(2), scalar(7)])
        }
        let both = try await check(dynamic, domain([-2, -2, 5, 6], [3, 3, 6, 8]), [source(), source(1)])
        contains(try both.charge(at: 0), 0); #expect(both.selectedSourceCount == 2)
    }

    @Test func outsideOriginalDomainInvalidInputsAndCyclesRefuse() async throws {
        let p = Node(id: 1), owner = try prepare([voltage(positive: p, negative: .ground)], nodes: [.ground, p])
        await #expect(throws: NativePrescribedVoltageFailure.outsideOriginalDomain(row: 0)) {
            try await check(owner, domain([-2, 5], [0.5, 6]), [source()])
        }
        await #expect(throws: NativePrescribedVoltageFailure.invalidBinding) {
            try await check(owner, domain([-2, 5], [3, 6]), [source(), source()])
        }
        do {
            _ = try await check(owner, domain([-2, 5], [3, 6]), [source(scale: 0)])
            Issue.record("Invalid source time scale admitted")
        } catch BoundPrescribedVoltageFailure.invalidTime {}
        let cycle = try prepare([voltage(positive: p, negative: .ground),
            voltage("V2", positive: p, negative: .ground, branch: .init(id: 1))], nodes: [.ground, p], branches: [.init(id: 0), .init(id: 1)])
        await #expect(throws: PrescribedVoltageReduction.Failure.dependentSources) {
            try await check(cycle, domain([-2, 5, 5], [3, 6, 6]), [source(), source(1)])
        }
    }

    @Test func currentFeedbackAtZeroAndOrdinaryOwnerCannotGrantAdmission() async throws {
        let p = Node(id: 1), branch = Branch(id: 0)
        let feedback = Instance(name: "F1", typeName: "cccs_ref", nodes: [p, .ground],
            parameters: ["f": .real(-1), "control_source": .string("V1")], referencedBranches: [branch])
        let owner = try prepare([voltage(positive: p, negative: .ground), feedback], nodes: [.ground, p])
        do { _ = try await check(owner, domain([0, 0], [0, 0]), [source(u: 0...0)]); Issue.record("Current feedback admitted at zero") }
        catch NativeConstitutiveInspection.Failure.unsupportedProducer(let name) { #expect(name == "F1") }
        let ordinary = try prepare([voltage(positive: p, negative: .ground)], nodes: [.ground, p], controlled: false)
        await #expect(throws: NativePrescribedVoltageFailure.missingControlledPreparation) {
            try await check(ordinary, domain([-2, 5], [3, 6]), [source()])
        }
    }

    @Test func sameOwnerCancellationStorageWorkAndRetainedCopiesRefund() async throws {
        #expect(throws: NativePrescribedVoltageFailure.capacityExceeded) {
            try NativePrescribedVoltageArithmetic.add(Int.max, 1)
        }
        #expect(throws: NativePrescribedVoltageFailure.capacityExceeded) {
            try NativePrescribedVoltageArithmetic.multiply(Int.max, 2)
        }
        let p = Node(id: 1), resources = Resources()
        do {
            let owner = try prepare([voltage(positive: p, negative: .ground)], nodes: [.ground, p], resources: resources)
            let baseline = resources.live
            resources.arm(work: 0)
            await #expect(throws: Refusal.work) { try await check(owner, domain([-2, 5], [3, 6]), [source()]) }
            resources.arm(storage: true)
            await #expect(throws: Refusal.storage) { try await check(owner, domain([-2, 5], [3, 6]), [source()]) }
            resources.arm()
            await #expect(throws: NativePrescribedVoltageFailure.capacityExceeded) {
                try await check(owner, domain([-2, 5], [3, 6]), [source()], retained: 1)
            }
            let cancelled = CancellationToken(); cancelled.cancel()
            do { _ = try await check(owner, domain([-2, 5], [3, 6]), [source()], cancellation: cancelled); Issue.record("Cancelled result") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            #expect(resources.live == baseline && resources.temporary == 0)
            var copied: NativePrescribedVoltageValues?
            do { copied = try await check(owner, domain([-2, 5], [3, 6]), [source()]) }
            withExtendedLifetime(copied) { #expect(resources.live > baseline) }
            copied = nil
            #expect(resources.live == baseline && resources.temporary == 0)
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
