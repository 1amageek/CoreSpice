import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR
import Foundation
import OSDIContracts
import OSDIRuntime
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Actual OSDI matched-chart evolution", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageEvolutionOSDITests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error, Equatable { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var reservations: UInt64 = 0
            var remaining: UInt64?; var refuseStorage = false
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var work: UInt64 { state.withLock { $0.work } }
        var reservations: UInt64 { state.withLock { $0.reservations } }
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
            try checkCancellation()
            try state.withLock { value in
                let current = kind == .liveOwnedBytes ? value.live : value.temporary
                guard !value.refuseStorage, byteCount <= 536_870_912 - current else { throw Refusal.storage }
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
    private let z = Node(id: 1), w = Node(id: 2), p = Node(id: 3), branch = Branch(id: 0)
    private func enclosure(_ lower: Double, _ upper: Double) throws -> E {
        try .init(center: .init(high: lower / 2 + upper / 2), radius: (upper - lower) / 2)
    }
    private func valueLimits() -> NativePrescribedVoltageLimits {
        .init(maximumNativeTerms: 64, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576,
            precisionBits: 192, reductionLimits: .init(maximumAxes: 16, maximumSources: 4,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    private func limits() -> NativePrescribedVoltageChartLimits {
        .init(maximumTriplets: 128, maximumRetainedBytes: 4_194_304, maximumWorkspaceBytes: 4_194_304,
            precisionBits: 192, values: valueLimits(),
            exact: .init(maximumRows: 16, maximumColumns: 16, maximumIntegerBits: 4096,
                maximumWorkspaceBytes: 2_097_152, maximumResultBytes: 1_048_576),
            root: .init(maximumDimension: 16, maximumJacobianNonzeros: 128,
                maximumPreconditionerNonzeros: 128, maximumWorkspaceBytes: 2_097_152, maximumResultBytes: 1_048_576))
    }
    private func range(_ fixture: NativeGlobalChargeOSDIFixture) -> OSDISmoothRangeCaptureInputs {
        .init(preparer: OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory),
            worker: fixture.capture.worker, source: fixture.capture.source,
            numericProfile: fixture.capture.numericProfile, options: fixture.capture.options)
    }
    private func linear(_ fixture: NativeGlobalChargeOSDIFixture, name: String, nodes: [Node],
        conductance: Double, capacitance: Double) throws -> Instance {
        let binding = try OSDIModelBinding(modelName: name, artifact: fixture.linear, descriptorIndex: 0,
            expectedDescriptorName: "linear_rc", modelParameters: [
                .init(name: "conductance", scope: .model, value: .real(conductance)),
                .init(name: "capacitance", scope: .model, value: .real(capacitance))])
        return try .init(name: name, typeName: "osdi", nodes: nodes, parameters: [:],
            osdi: .resolved(OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])))
    }
    private func devices(_ fixture: NativeGlobalChargeOSDIFixture, inputCapacitance: Double,
        dynamicConductance: Double = 0) throws -> [Instance] {
        var result = try [Instance(name: "Vselected", typeName: "vsource", nodes: [p, .ground],
                parameters: ["v": .real(0)], ownedBranches: [branch]),
            linear(fixture, name: "NQ", nodes: [z, p], conductance: dynamicConductance, capacitance: 1),
            linear(fixture, name: "NG", nodes: [w, p], conductance: 1, capacitance: 0),
            // Both aliased raw rows/columns must sum before the source current is reconstructed.
            linear(fixture, name: "Nalias", nodes: [w, w], conductance: 0, capacitance: 1),
            Instance(name: "R1", typeName: "resistor", nodes: [w, z], parameters: ["r": .real(1)])]
        if inputCapacitance != 0 {
            result.append(try Instance(name: "Cinput", typeName: "capacitor", nodes: [p, .ground],
                parameters: ["c": .real(inputCapacitance)]))
        }
        return result
    }
    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture, devices: [Instance], resources: Resources) async throws -> PreparedNativeCircuit {
        let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: devices.count,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let owner = try await NativeCircuitPreparer().prepare(ir: .init(nodes: [.ground, z, w, p], branches: [branch], instances: devices),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15), limits: fixture.nativeLimits,
            numericalLimits: fixture.numerical, resources: resources, osdi: runtime,
            constitutive: fixture.snapshot, cancellation: .init())
        do {
            let programs = try #require(owner.record.constitutiveBacking?.programs)
            let foreign = devices.filter { $0.osdi != nil }
            try #require(programs.count == 3 && foreign.count == 3)
            for i in programs.indices {
                try #require(programs[i].modelReference == foreign[i].osdi?.resolved.binding.artifact)
                try #require(programs[i].programDigest.hexadecimalValue
                    == "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203")
            }
            let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
            let wRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(w)])
            try #require(zRow < wRow)
        } catch { try owner.close(); throw error }
        return consume owner
    }
    private func chart(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        currentDomain: ClosedRange<Double> = -10...10) async throws -> NativePrescribedVoltageChart {
        let count = owner.plan.topology.dimension
        var lower = try [CompensatedValue](repeating: .init(high: 0), count: count)
        var upper = try [CompensatedValue](repeating: .init(high: 2), count: count)
        let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
        let wRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(w)])
        let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
        let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
        // These are real padded cells, not a point evaluation substituted for the certified box.
        lower[zRow] = try .init(high: 1.48); upper[zRow] = try .init(high: 1.52)
        lower[wRow] = try .init(high: 1.23); upper[wRow] = try .init(high: 1.27)
        lower[pRow] = try .init(high: 0.999); upper[pRow] = try .init(high: 1.001)
        lower[iRow] = try .init(high: currentDomain.lowerBound); upper[iRow] = try .init(high: currentDomain.upperBound)
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        let values = try await owner.enclosePrescribedVoltageValues(
            originalDomain: .init(lower: lower, upper: upper, lowerContext: context, upperContext: context),
            sources: [.init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: 2,
                normalized: 0.5...0.5, leftSlope: 1...1, rightSlope: 2...2)],
            reducedCoordinates: [enclosure(1.49, 1.51), enclosure(1.24, 1.26)],
            capture: fixture.capture, limits: valueLimits(), cancellation: .init())
        return try await owner.certifyPrescribedVoltageChart(values: values, algebraicRows: [1],
            chargeParameters: [enclosure(0.5, 0.5)], center: [.init(high: 1.5), .init(high: 1.25)],
            inverse: SparseStructure(dimension: 2, rowPointers: [0, 1, 3], columnIndices: [0, 0, 1]),
            inverseValues: [1, 0.5, 0.5], capture: fixture.capture, range: range(fixture), limits: limits(), cancellation: .init())
    }
    private func evolutionLimits() -> NativePrescribedVoltageEvolutionLimits {
        .init(maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576)
    }
    private func contains(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = value.center.bounds
        #expect((bounds.lower - value.radius).nextDown <= expected
            && (bounds.upper + value.radius).nextUp >= expected, sourceLocation: sourceLocation)
    }
    private func bounds(_ value: E) -> ClosedRange<Double> {
        let bounds = value.center.bounds
        return (bounds.lower - value.radius).nextDown ... (bounds.upper + value.radius).nextUp
    }

    @Test func sameActualChartRatesRequireTheEliminatedInputChargeForBothSourceCurrents() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        var baselineImages: [E] = [], baselineNorm: Double?
        do {
            for capacitance in [0.0, 3.0] {
                do {
                    let owner = try await prepare(fixture, devices: devices(fixture, inputCapacitance: capacitance), resources: resources)
                    do {
                        let actualChart = try await chart(owner, fixture)
                        #expect(actualChart.dimension == 2 && actualChart.chargeCoordinateCount == 1)
                        let images = try [actualChart.image(at: 0), actualChart.image(at: 1)]
                        if capacitance == 0 {
                            baselineImages = images; baselineNorm = actualChart.normUpperBound
                        } else {
                            // C(p,ground) disappears under P but remains in the full original p row.
                            #expect(images == baselineImages && actualChart.normUpperBound == baselineNorm)
                        }
                        let result = try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                            limits: evolutionLimits(), cancellation: .init())
                        #expect(result.dimension == owner.plan.topology.dimension)
                        #expect(result.reducedCoordinateCount == 2 && result.chargeCoordinateCount == 1)
                        contains(try result.chargeRate(at: 0), -0.25)
                        let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
                        let wRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(w)])
                        let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                        let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                        for side in [NativePrescribedVoltageReconstruction.Side.left, .right] {
                            let phiDot = side == .left ? 1.0 : 2.0
                            // deltaV=2 and T=2 convert the two normalized slopes to SI exactly once.
                            contains(try result.reducedRate(at: 0, side: side), phiDot - 0.25)
                            contains(try result.reducedRate(at: 1, side: side), phiDot - 0.125)
                            contains(try result.fullChargeRate(at: zRow, side: side), -0.25)
                            contains(try result.fullChargeRate(at: wRow, side: side), 0)
                            contains(try result.fullChargeRate(at: pRow, side: side), 0.25 + capacitance * phiDot)
                            contains(try result.coordinate(at: zRow, side: side), 1.5)
                            contains(try result.coordinate(at: wRow, side: side), 1.25)
                            contains(try result.coordinate(at: pRow, side: side), 1)
                            let current = try result.selectedCurrent(at: 0, side: side)
                            contains(current, -capacitance * phiDot)
                            let branchCoordinate = try result.coordinate(at: iRow, side: side)
                            #expect(current == branchCoordinate)
                            // The full-D enclosure must distinguish a missing C3 term, not just contain an oracle.
                            let interval = bounds(current)
                            if capacitance == 0 {
                                #expect(interval.lowerBound > -1 && interval.upperBound < 1)
                            } else {
                                #expect(interval.upperBound < -1)
                                #expect(interval.lowerBound > -capacitance * phiDot - 1
                                    && interval.upperBound < -capacitance * phiDot + 1)
                            }
                        }
                    } catch { try owner.close(); throw error }
                    try owner.close()
                }
                #expect(resources.live == 0 && resources.temporary == 0)
            }
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }

    @Test func everyOriginalCurrentSectionMustContainBothActualSides() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        do {
            for refusesLeft in [true, false] {
                do {
                    let owner = try await prepare(fixture, devices: devices(fixture, inputCapacitance: 3), resources: resources)
                    do {
                        // Each section admits the other side; the chart does not constrain formal source current.
                        let actualChart = try await chart(owner, fixture, currentDomain: refusesLeft ? -10 ... -4 : -5 ... -1)
                        let baseline = resources.live + resources.temporary
                        let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                        do {
                            _ = try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                                limits: evolutionLimits(), cancellation: .init())
                            Issue.record("Evolution escaped an actual selected-current section")
                        } catch NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(let row, let side) {
                            #expect(row == iRow && side == (refusesLeft ? .left : .right))
                        }
                        #expect(resources.live + resources.temporary == baseline)
                    } catch { try owner.close(); throw error }
                    try owner.close()
                }
                #expect(resources.live == 0 && resources.temporary == 0)
            }
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }

    @Test func actualChartOwnerQuotaCancellationAndFinalEvolutionCopyRetainTheOriginalAdmission() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        var retained: NativePrescribedVoltageEvolution?
        do {
            let actualDevices = try devices(fixture, inputCapacitance: 3)
            let owner = try await prepare(fixture, devices: actualDevices, resources: resources)
            do {
                let actualChart = try await chart(owner, fixture)
                let baseline = resources.live + resources.temporary
                do {
                    let other = try await prepare(fixture, devices: actualDevices, resources: resources)
                    do {
                        #expect(throws: NativePrescribedVoltageEvolutionFailure.wrongOwner) {
                            try other.reconstructPrescribedVoltageChart(chart: actualChart,
                                limits: evolutionLimits(), cancellation: .init())
                        }
                    } catch { try other.close(); throw error }
                    try other.close()
                }
                resources.arm(work: 0)
                #expect(throws: Refusal.work) {
                    try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                        limits: evolutionLimits(), cancellation: .init())
                }
                resources.arm(storage: true)
                #expect(throws: Refusal.storage) {
                    try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                        limits: evolutionLimits(), cancellation: .init())
                }
                resources.arm()
                let cancelled = CancellationToken(); cancelled.cancel()
                do {
                    _ = try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                        limits: evolutionLimits(), cancellation: cancelled)
                    Issue.record("Cancelled actual evolution published")
                } catch NativeConstitutiveInspection.Failure.cancelled {}
                #expect(resources.live + resources.temporary == baseline)
                retained = try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                    limits: evolutionLimits(), cancellation: .init())
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live > 0)
        do {
            let copy = try #require(retained)
            retained = nil
            contains(try copy.selectedCurrent(at: 0, side: .left), -3)
            contains(try copy.selectedCurrent(at: 0, side: .right), -6)
            #expect(copy.chargeStateLipschitzUpperBound >= 2 && copy.chargeStateLipschitzUpperBound < 2.01)
            #expect(resources.live > 0)
            withExtendedLifetime(copy) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func sameActualChargeChartRetainsTheOriginalDomainStaticDerivativeNorm() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        var images: [E] = [], eta: Double?
        var jacobianValues: (E, E, E)?
        do {
            for (conductance, aliasConductance, expectedNorm) in [(0.0, 0.0, 2.0), (0.5, 0, 2.5), (0, 0.25, 3)] {
                do {
                    var instances = try devices(fixture, inputCapacitance: 0, dynamicConductance: conductance)
                    if aliasConductance != 0 {
                        // Keep raw Q zero so only the conservative G alias sum changes.
                        instances[3] = try linear(fixture, name: "Nalias", nodes: [z, z],
                            conductance: aliasConductance, capacitance: 0)
                    }
                    let owner = try await prepare(fixture, devices: instances, resources: resources)
                    do {
                        let actualChart = try await chart(owner, fixture)
                        let matched = try actualChart.evolutionPayload(record: owner.record)
                        try #require(matched.jacobian.dimension == 2
                            && matched.jacobian.rowPointers == [0, 1, 3]
                            && matched.jacobian.columnIndices == [0, 0, 1]
                            && matched.jacobianValues.count == 3)
                        #expect(matched.inverse.dimension == 2 && matched.inverse.rowPointers == [0, 1, 3]
                            && matched.inverse.columnIndices == [0, 0, 1] && matched.inverseValues == [1, 0.5, 0.5])
                        let coefficients = matched.jacobianValues
                        if let first = jacobianValues {
                            #expect(coefficients[0] == first.0 && coefficients[1] == first.1 && coefficients[2] == first.2)
                        } else { jacobianValues = (coefficients[0], coefficients[1], coefficients[2]) }
                        let actualImages = try [actualChart.image(at: 0), actualChart.image(at: 1)]
                        if images.isEmpty { images = actualImages; eta = actualChart.normUpperBound }
                        if aliasConductance == 0 { #expect(images == actualImages) }
                        #expect(eta == actualChart.normUpperBound)
                        contains(actualImages[0], 1.5)
                        contains(actualImages[1], 1.25)
                        let before = resources.work, reservations = resources.reservations
                        let bound = try NativePrescribedVoltageEvolutionInverse.chargeStateLipschitzUpperBound(
                            record: owner.record, chart: actualChart, cancellation: .init())
                        // Two rows + three Y slots at three units each + six scalar operations.
                        #expect(resources.work - before == 17 && resources.reservations == reservations)
                        // Y=[1,0;.5,.5] has exact norm 1; eta is this actual retained chart's bound.
                        let rational = expectedNorm / (1 - actualChart.normUpperBound)
                        #expect(bound >= rational && bound < rational + 1e-10)
                        let result = try owner.reconstructPrescribedVoltageChart(chart: actualChart,
                            limits: evolutionLimits(), cancellation: .init())
                        #expect(result.chargeStateLipschitzUpperBound == bound)
                        // G0.5 changes the true |Dq f| from .5 to 1; the self-alias has true contribution zero.
                        #expect(bound >= (conductance == 0 ? 0.5 : 1))
                    } catch { try owner.close(); throw error }
                    try owner.close()
                }
                #expect(resources.live == 0 && resources.temporary == 0)
            }
        } catch { try await fixture.close(); throw error }
        try await fixture.close()
    }
}
