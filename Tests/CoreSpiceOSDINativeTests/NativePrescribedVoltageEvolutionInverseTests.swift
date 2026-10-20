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

@Suite("Native chart inverse action", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageEvolutionInverseTests {
    private typealias Inverse = NativePrescribedVoltageEvolutionInverse
    private typealias E = CompensatedEnclosure
    private func scalar(_ value: Double, radius: Double = 0) throws -> E {
        try .init(center: .init(high: value), radius: radius)
    }
    private func bounds(_ value: E) -> (Double, Double) {
        let b = value.center.bounds
        return value.radius == 0 ? (b.lower, b.upper) : ((b.lower - value.radius).nextDown, (b.upper + value.radius).nextUp)
    }
    private func contains(_ value: E, lower: Double, upper: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let actual = bounds(value)
        #expect(actual.0 <= lower && actual.1 >= upper, sourceLocation: sourceLocation)
    }

    @Test func directedScalarTailBoundsTheIndependentRationalRemainder() throws {
        // These are arithmetic tests only; they cannot create a checked Evolution owner.
        let tail = try Inverse.tailUpperBound(normUpperBound: 0.25, maximumMagnitude: 1.96875)
        #expect(tail >= 0.65625 && tail < 0.65625 + 0x1p-45)
        let third = try Inverse.tailUpperBound(normUpperBound: 0.25, maximumMagnitude: 1)
        #expect(third >= 1.0 / 3.0 && third < 1.0 / 3.0 + 0x1p-45)
        #expect(try Inverse.tailUpperBound(normUpperBound: 0, maximumMagnitude: Double.greatestFiniteMagnitude) == 0)
        #expect(try Inverse.tailUpperBound(normUpperBound: 1.0.nextDown, maximumMagnitude: 0) == 0)
    }

    @Test func positiveUnderflowNeverBecomesAZeroTailAndOverflowRefuses() throws {
        let tiny = try Inverse.tailUpperBound(normUpperBound: .leastNonzeroMagnitude, maximumMagnitude: .leastNonzeroMagnitude)
        #expect(tiny >= Double.leastNonzeroMagnitude)
        let finite = try Inverse.tailUpperBound(normUpperBound: 1.0.nextDown, maximumMagnitude: 1)
        #expect(finite.isFinite && finite >= 0x1p53 - 1)
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try Inverse.tailUpperBound(normUpperBound: 1.0.nextDown, maximumMagnitude: .greatestFiniteMagnitude)
        }
        for (q, m) in [(1.0, 1.0), (-0.25, 1.0), (Double.nan, 1.0), (0.25, -1.0), (0.25, Double.infinity)] {
            do { _ = try Inverse.tailUpperBound(normUpperBound: q, maximumMagnitude: m); Issue.record("Invalid tail arithmetic admitted") }
            catch NativePrescribedVoltageEvolutionFailure.invalidInput {}
        }
    }

    @Test func genuineNoncommutingChartUsesItsOwnNormWithoutAdditionalStorageAdmission() async throws {
        let resources = Resources()
        do {
            let owner = try prepare(resources: resources), chart = try await makeChart(owner)
            #expect(chart.normUpperBound >= 0.25 && chart.normUpperBound < 0.25 + 0x1p-40)
            let control = try #require(owner.record.constitutiveBacking?.control)
            let lease = try control.reserveStorage(byteCount: 2 * MemoryLayout<E>.stride + MemoryLayout<[E]>.stride)
            try control.checkpoint(workUnits: 2)
            var output = try [E](repeating: scalar(0), count: 2)
            let reservations = resources.reservations, before = resources.live + resources.temporary
            let rhs = try [scalar(2), scalar(1)]
            let workBefore = resources.units
            try apply(owner, chart, rhs: rhs, into: &output)
            // J=[2,0;-1,1], Y=[.5,0;.375,1], W=(1,1.75), q=1/4.
            // True J^-1*b=(1,2). A detached q=0 would return 1.75 for the second component.
            contains(output[0], lower: 1, upper: 1)
            contains(output[1], lower: 2, upper: 2)
            #expect(output[1].radius >= 7.0 / 12.0 && output[1].radius < 0.6)
            #expect(resources.reservations == reservations)
            #expect(resources.live + resources.temporary == before)
            let second = bounds(output[1])
            print("inverse coupled n=2 qUpper=\(chart.normUpperBound) work=\(resources.units - workBefore) additionalReservations=\(resources.reservations - reservations) image1=[\(second.0),\(second.1)] storageUnchanged=\(resources.live + resources.temporary == before)")
            withExtendedLifetime(lease) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func intervalRightHandSideEnclosesIndependentExactInverseCornersCumulatively() async throws {
        let resources = Resources()
        do {
            let owner = try prepare(resources: resources), chart = try await makeChart(owner)
            let control = try #require(owner.record.constitutiveBacking?.control)
            let lease = try control.reserveStorage(byteCount: 2 * MemoryLayout<E>.stride + MemoryLayout<[E]>.stride)
            try control.checkpoint(workUnits: 2)
            var output = try [E](repeating: scalar(0), count: 2)
            let rhs = try [scalar(2, radius: 0.25), scalar(1, radius: 0.125)]
            try control.checkpoint(workUnits: 7)
            let before = resources.units
            try apply(owner, chart, rhs: rhs, into: &output)
            let once = resources.units
            contains(output[0], lower: 0.21875, upper: 1.78125)
            contains(output[1], lower: 0.875, upper: 2.625)
            // Independent exact inverse is [1/2,0;1/2,1], so all RHS corners lie here.
            contains(output[0], lower: 0.875, upper: 1.125)
            contains(output[1], lower: 1.75, upper: 2.25)
            let reservations = resources.reservations
            let firstImage = bounds(output[0]), secondImage = bounds(output[1])
            print("inverse interval n=2 qUpper=\(chart.normUpperBound) work=\(once - before) image0=[\(firstImage.0),\(firstImage.1)] image1=[\(secondImage.0),\(secondImage.1)]")
            try apply(owner, chart, rhs: rhs, into: &output)
            #expect(once > before && resources.units - once == once - before)
            #expect(resources.reservations == reservations)
            withExtendedLifetime(lease) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func actualOwnerShapeCancellationAndWorkFailureCannotPublishAnAction() async throws {
        let resources = Resources()
        do {
            let owner = try prepare(resources: resources), other = try prepare(), chart = try await makeChart(owner)
            let control = try #require(owner.record.constitutiveBacking?.control)
            let lease = try control.reserveStorage(byteCount: 2 * MemoryLayout<E>.stride + MemoryLayout<[E]>.stride)
            try control.checkpoint(workUnits: 2)
            var output = try [E](repeating: scalar(0), count: 2)
            let rhs = try [scalar(2), scalar(1)]
            do { try apply(other, chart, rhs: rhs, into: &output); Issue.record("Foreign preparation accepted chart certificate") }
            catch NativePrescribedVoltageEvolutionFailure.wrongOwner {}
            do { try apply(owner, chart, rhs: [scalar(1)], into: &output); Issue.record("Incomplete RHS admitted") }
            catch NativePrescribedVoltageEvolutionFailure.invalidInput {}
            output.removeLast()
            do { try apply(owner, chart, rhs: rhs, into: &output); Issue.record("Incomplete output admitted") }
            catch NativePrescribedVoltageEvolutionFailure.invalidInput {}
            try control.checkpoint(workUnits: 1)
            output.append(try scalar(0))
            let cancelled = CancellationToken(); cancelled.cancel()
            do { try apply(owner, chart, rhs: rhs, into: &output, cancellation: cancelled); Issue.record("Cancelled action succeeded") }
            catch NativeConstitutiveInspection.Failure.cancelled {}
            let reservations = resources.reservations, baseline = resources.live + resources.temporary
            resources.refuseWork = true
            do { try apply(owner, chart, rhs: rhs, into: &output); Issue.record("Original resource refusal was hidden") }
            catch Resources.Refusal.work {}
            resources.refuseWork = false
            #expect(resources.reservations == reservations && resources.live + resources.temporary == baseline)
            try apply(owner, chart, rhs: rhs, into: &output)
            contains(output[1], lower: 2, upper: 2)
            withExtendedLifetime(lease) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func genuineSparseActionOverflowAndNonfiniteRHSRefuseWithoutAllocating() async throws {
        let resources = Resources()
        do {
            let owner = try prepare(resources: resources), chart = try await makeChart(owner)
            let control = try #require(owner.record.constitutiveBacking?.control)
            let lease = try control.reserveStorage(byteCount: 2 * MemoryLayout<E>.stride + MemoryLayout<[E]>.stride)
            try control.checkpoint(workUnits: 2)
            var output = try [E](repeating: scalar(0), count: 2)
            let reservations = resources.reservations
            #expect(throws: NumericalStateError.self) {
                try apply(owner, chart, rhs: [scalar(.greatestFiniteMagnitude), scalar(.greatestFiniteMagnitude)], into: &output)
            }
            #expect(throws: NumericalStateError.self) {
                try apply(owner, chart, rhs: [scalar(.greatestFiniteMagnitude, radius: .greatestFiniteMagnitude), scalar(0)], into: &output)
            }
            #expect(resources.reservations == reservations)
            try apply(owner, chart, rhs: [scalar(0), scalar(0)], into: &output)
            #expect(output.allSatisfy { $0.center == .zero && $0.radius == 0 })
            withExtendedLifetime(lease) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    private func apply(_ owner: borrowing PreparedNativeCircuit, _ chart: NativePrescribedVoltageChart,
        rhs: [E], into output: inout [E], cancellation: CancellationToken = .init()) throws {
        var span = output.mutableSpan
        try Inverse.enclose(record: owner.record, chart: chart, rightHandSide: rhs.span, into: &span, cancellation: cancellation)
    }

    private func prepare(resources: Resources = .init()) throws -> PreparedNativeCircuit {
        let p = Node(id: 1), d = Node(id: 2), x = Node(id: 3), branch = Branch(id: 0)
        let ir = CircuitIR(nodes: [.ground, p, d, x], branches: [branch], instances: [
            .init(name: "V1", typeName: "vsource", nodes: [p, .ground], parameters: ["v": .real(0)], ownedBranches: [branch]),
            .init(name: "Cd", typeName: "capacitor", nodes: [d, .ground], parameters: ["c": .real(2)]),
            .init(name: "Rx", typeName: "resistor", nodes: [x, d], parameters: ["r": .real(1)])], branchNames: [branch: "V1"])
        return try NativeCircuitPreparer().prepareNativeConstitutive(ir: ir, registry: .standard(),
            operatingConditions: .init(temperatureKelvin: 300.15),
            limits: .init(maximumDeviceCount: 4, maximumMatrixDimension: 4, maximumAllocationBytes: 268_435_456),
            numericalLimits: .init(maximumAcceptedSteps: 10, maximumSolveAttempts: 10, maximumNewtonIterations: 10,
                maximumSavedScalars: 16, maximumMatrixDimension: 4, maximumWorkUnits: 1_000_000, maximumBreakpoints: 10),
            resources: resources, cancellation: .init())
    }

    private func makeChart(_ owner: borrowing PreparedNativeCircuit) async throws -> NativePrescribedVoltageChart {
        let valuesLimits = NativePrescribedVoltageLimits(maximumNativeTerms: 64, maximumRetainedBytes: 131_072,
            maximumWorkspaceBytes: 1_048_576, precisionBits: 192,
            reductionLimits: .init(maximumAxes: 16, maximumSources: 2, maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0, timeLow: 0)
        let end = try OSDIPrecisionContext(mode: .transient, timeHigh: 1, timeLow: 0)
        let domain = try NativeGlobalChargeDomain(lower: [-1.0, -4, -4, -10].map { try .init(high: $0) },
            upper: [1.0, 4, 4, 10].map { try .init(high: $0) }, lowerContext: context, upperContext: end)
        let source = NativePrescribedVoltageSource(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 1,
            timeOrigin: 0, timeScale: 1, normalized: 0...0, leftSlope: 0...0, rightSlope: 0...0)
        let values = try await owner.enclosePrescribedVoltageValues(originalDomain: domain, sources: [source],
            reducedCoordinates: [scalar(0, radius: 1), scalar(0, radius: 1)], capture: nil,
            limits: valuesLimits, cancellation: .init())
        let inverse = try SparseStructure(dimension: 2, rowPointers: [0, 1, 3], columnIndices: [0, 0, 1])
        return try await owner.certifyPrescribedVoltageChart(values: values, algebraicRows: [1], chargeParameters: [scalar(0)],
            center: [.zero, .zero], inverse: inverse, inverseValues: [0.5, 0.375, 1], capture: nil, range: nil,
            limits: .init(maximumTriplets: 64, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576,
                precisionBits: 192, values: valuesLimits,
                exact: .init(maximumRows: 16, maximumColumns: 16, maximumIntegerBits: 4096,
                    maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576),
                root: .init(maximumDimension: 16, maximumJacobianNonzeros: 64, maximumPreconditionerNonzeros: 64,
                    maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576)), cancellation: .init())
    }

    private final class Resources: SPICESourceResourceAccounting {
        enum Refusal: Error { case work }
        private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var units: UInt64 = 0; var reservations = 0; var refuseWork = false }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var units: UInt64 { state.withLock { $0.units } }
        var reservations: Int { state.withLock { $0.reservations } }
        var refuseWork: Bool {
            get { state.withLock { $0.refuseWork } }
            set { state.withLock { $0.refuseWork = newValue } }
        }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                if value.refuseWork { throw Refusal.work }
                let (next, overflow) = value.units.addingReportingOverflow(units)
                guard !overflow else { throw Refusal.work }; value.units = next
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            state.withLock { value in
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
                value.reservations += 1
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { value in
                if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
            }}
        }
    }
}
