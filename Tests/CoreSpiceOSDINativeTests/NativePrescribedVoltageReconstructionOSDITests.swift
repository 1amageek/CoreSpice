import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceParsedIR
import Foundation
import OSDIRuntime
import Synchronization
import Testing
@testable import CoreSpice

@Suite("Actual OSDI prescribed voltage current reconstruction", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageReconstructionOSDITests {
    private typealias E = CompensatedEnclosure
    private final class Resources: SPICESourceResourceAccounting {
        private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0 }
        private let state = Mutex(State())
        private enum Failure: Error { case capacity }
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                guard units <= 8_000_000_000 - value.work else { throw Failure.capacity }
                value.work += units
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            try state.withLock { value in
                let current = kind == .liveOwnedBytes ? value.live : value.temporary
                guard byteCount <= 536_870_912 - current else { throw Failure.capacity }
                if kind == .liveOwnedBytes { value.live += byteCount } else { value.temporary += byteCount }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
    }
    private func scalar(_ value: Double) throws -> E { try .init(center: .init(high: value)) }
    private func valueLimits() -> NativePrescribedVoltageLimits {
        .init(maximumNativeTerms: 64, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576,
            precisionBits: 192, reductionLimits: .init(maximumAxes: 16, maximumSources: 4,
                maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576))
    }
    private func rateLimits() -> NativePrescribedVoltageReconstructionLimits {
        .init(maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576, precisionBits: 192)
    }
    private func source() -> NativePrescribedVoltageSource {
        .init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: 2,
            normalized: 0.5...0.5, leftSlope: 1...1, rightSlope: 2...2)
    }
    private func range(_ fixture: NativeGlobalChargeOSDIFixture) -> OSDISmoothRangeCaptureInputs {
        .init(preparer: OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory),
            worker: fixture.capture.worker, source: fixture.capture.source,
            numericProfile: fixture.capture.numericProfile, options: fixture.capture.options)
    }
    private func domain(_ owner: borrowing PreparedNativeCircuit, branch: Branch,
        current: ClosedRange<Double> = -20 ... -1) throws -> NativeGlobalChargeDomain {
        let n = owner.plan.topology.dimension, i = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
        var lower = try [CompensatedValue](repeating: .init(high: -4), count: n)
        var upper = try [CompensatedValue](repeating: .init(high: 4), count: n)
        lower[i] = try .init(high: current.lowerBound); upper[i] = try .init(high: current.upperBound)
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return .init(lower: lower, upper: upper, lowerContext: context, upperContext: context)
    }
    private func instances(_ fixture: NativeGlobalChargeOSDIFixture, p: Node, n: Node, branch: Branch,
        floating: Bool) throws -> [Instance] {
        var devices = [Instance(name: "Vselected", typeName: "vsource", nodes: [p, n],
            parameters: ["v": .real(0)], ownedBranches: [branch]),
            try fixture.instance("Nlinear", nodes: [p, n]),
            try fixture.instance("NparabolaAlias", nodes: [p, p], capacitance: nil),
            Instance(name: "R4", typeName: "resistor", nodes: [p, n], parameters: ["r": .real(4)]),
            Instance(name: "C2", typeName: "capacitor", nodes: [p, n], parameters: ["c": .real(2)])]
        if floating { devices.append(try fixture.instance("Nground", nodes: [n, .ground], capacitance: 2)) }
        return devices
    }
    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture, devices: [Instance], nodes: [Node],
        branch: Branch, resources: Resources) async throws -> PreparedNativeCircuit {
        let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: devices.count,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let owner = try await NativeCircuitPreparer().prepare(ir: .init(nodes: nodes, branches: [branch], instances: devices),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15), limits: fixture.nativeLimits,
            numericalLimits: fixture.numerical, resources: resources, osdi: runtime,
            constitutive: fixture.snapshot, cancellation: .init())
        do {
            let programs = try #require(owner.record.constitutiveBacking?.programs)
            let foreign = devices.filter { $0.osdi != nil }
            try #require(programs.count == foreign.count)
            for index in programs.indices {
                try #require(programs[index].modelReference == foreign[index].osdi?.resolved.binding.artifact)
                try #require(programs[index].programDigest.hexadecimalValue == (programs[index].modelReference == fixture.linear
                    ? "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203"
                    : "22bf1ebc619fcf7473d5845ad970638ef9a3a3123a8592b50538f522ebebc205"))
            }
        } catch { try owner.close(); throw error }
        return consume owner
    }
    private func values(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        branch: Branch, reduced: [E], current: ClosedRange<Double> = -20 ... -1) async throws -> NativePrescribedVoltageValues {
        try await owner.enclosePrescribedVoltageValues(originalDomain: domain(owner, branch: branch, current: current),
            sources: [source()], reducedCoordinates: reduced, capture: fixture.capture,
            limits: valueLimits(), cancellation: .init())
    }
    private func contains(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = value.center.bounds
        let lower = (bounds.lower - value.radius).nextDown, upper = (bounds.upper + value.radius).nextUp
        #expect(lower <= expected && expected <= upper && value.radius < 1e-10, sourceLocation: sourceLocation)
    }

    @Test func actualGroundedNonlinearChargeNeedsBothOneSidedInputDerivatives() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), branch = Branch(id: 0)
        do {
            let owner = try await prepare(fixture, devices: instances(fixture, p: p, n: .ground, branch: branch, floating: false),
                nodes: [.ground, p], branch: branch, resources: resources)
            do {
                let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                let image = try await values(owner, fixture, branch: branch, reduced: [])
                contains(try image.charge(at: pRow), 5)
                let result = try await owner.reconstructPrescribedVoltageCurrents(values: image,
                    leftReducedRates: [], rightReducedRates: [], range: range(fixture), limits: rateLimits(), cancellation: .init())
                #expect(result.dimension == 2 && result.reducedCoordinateCount == 0)
                for (side, rate, current) in [(NativePrescribedVoltageReconstruction.Side.left, 6.0, -6.25), (.right, 12.0, -12.25)] {
                    contains(try result.stateChargeRate(at: pRow, side: side), 0)
                    contains(try result.prescribedChargeRate(at: pRow, side: side), rate)
                    contains(try result.coordinate(at: pRow, side: side), 1)
                    contains(try result.coordinate(at: iRow, side: side), current)
                    // Original KCL: i + v/4 + (3 + 1 + 2v) * v' = 0 at v=1.
                    contains(try result.coordinate(at: iRow, side: side).adding(scalar(0.25 + rate)), 0)
                    for row in 0..<2 { contains(try result.originalResidual(at: row, side: side), 0) }
                }
                try owner.close()
                contains(try result.coordinate(at: iRow, side: .right), -12.25)
                #expect(resources.live > 0)
            } catch { try owner.close(); throw error }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func actualFloatingAliasAndGroundRetainStateAndInputChainRuleSeparately() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        let p = Node(id: 1), n = Node(id: 2), branch = Branch(id: 0)
        do {
            let owner = try await prepare(fixture, devices: instances(fixture, p: p, n: n, branch: branch, floating: true),
                nodes: [.ground, p, n], branch: branch, resources: resources)
            do {
                let pRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(p)])
                let nRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(n)])
                let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                try #require(pRow < nRow)
                let image = try await values(owner, fixture, branch: branch, reduced: [scalar(0.5)])
                contains(try image.charge(at: pRow), 3.75); contains(try image.charge(at: nRow), -4)
                let result = try await owner.reconstructPrescribedVoltageCurrents(values: image,
                    leftReducedRates: [scalar(0.5)], rightReducedRates: [scalar(1)],
                    range: range(fixture), limits: rateLimits(), cancellation: .init())
                #expect(result.reducedCoordinateCount == 1)
                for (side, factor) in [(NativePrescribedVoltageReconstruction.Side.left, 1.0), (.right, 2.0)] {
                    contains(try result.coordinate(at: pRow, side: side), 0.5)
                    contains(try result.coordinate(at: nRow, side: side), -0.5)
                    contains(try result.stateChargeRate(at: pRow, side: side), factor)
                    contains(try result.stateChargeRate(at: nRow, side: side), factor)
                    contains(try result.prescribedChargeRate(at: pRow, side: side), 3 * factor)
                    contains(try result.prescribedChargeRate(at: nRow, side: side), -5 * factor)
                    contains(try result.coordinate(at: iRow, side: side), -0.25 - 4 * factor)
                    for row in 0..<3 { contains(try result.originalResidual(at: row, side: side), 0) }
                    contains(try result.reducedResidual(at: 0, side: side), 0)
                }
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func actualReconstructionRequiresOriginalOwnerSmoothCaptureAndCurrentDomain() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources(), p = Node(id: 1), branch = Branch(id: 0)
        do {
            let devices = try instances(fixture, p: p, n: .ground, branch: branch, floating: false)
            let owner = try await prepare(fixture, devices: devices, nodes: [.ground, p], branch: branch, resources: resources)
            do {
                let image = try await values(owner, fixture, branch: branch, reduced: [])
                let baseline = resources.live + resources.temporary
                await #expect(throws: NativePrescribedVoltageReconstructionFailure.missingSmoothCapture) {
                    try await owner.reconstructPrescribedVoltageCurrents(values: image, leftReducedRates: [], rightReducedRates: [],
                        range: nil, limits: rateLimits(), cancellation: .init())
                }
                let originalRange = range(fixture)
                let changedRange = try OSDISmoothRangeCaptureInputs(preparer: originalRange.preparer,
                    worker: originalRange.worker, source: originalRange.source,
                    numericProfile: .init(algorithm: .sha256, hexadecimalValue: String(repeating: "0", count: 64)),
                    options: originalRange.options)
                await #expect(throws: NativePrescribedVoltageReconstructionFailure.invalidBinding) {
                    try await owner.reconstructPrescribedVoltageCurrents(values: image, leftReducedRates: [], rightReducedRates: [],
                        range: changedRange, limits: rateLimits(), cancellation: .init())
                }
                do {
                    let other = try await prepare(fixture, devices: devices, nodes: [.ground, p], branch: branch, resources: resources)
                    do {
                        await #expect(throws: NativePrescribedVoltageReconstructionFailure.wrongOwner) {
                            try await other.reconstructPrescribedVoltageCurrents(values: image, leftReducedRates: [], rightReducedRates: [],
                                range: range(fixture), limits: rateLimits(), cancellation: .init())
                        }
                    } catch { try other.close(); throw error }
                    try other.close()
                }
                do {
                    let tight = try await values(owner, fixture, branch: branch, reduced: [], current: -10 ... -1)
                    let row = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                    await #expect(throws: NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(row: row, side: .right)) {
                        try await owner.reconstructPrescribedVoltageCurrents(values: tight, leftReducedRates: [], rightReducedRates: [],
                            range: range(fixture), limits: rateLimits(), cancellation: .init())
                    }
                }
                #expect(resources.live + resources.temporary == baseline)
                let result = try await owner.reconstructPrescribedVoltageCurrents(values: image, leftReducedRates: [], rightReducedRates: [],
                    range: range(fixture), limits: rateLimits(), cancellation: .init())
                let row = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
                contains(try result.coordinate(at: row, side: .right), -12.25)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
