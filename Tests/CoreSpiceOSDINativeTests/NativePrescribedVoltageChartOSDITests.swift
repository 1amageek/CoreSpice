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

@Suite("Actual OSDI strong-null charge charts", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageChartOSDITests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error, Equatable { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var remaining: UInt64?; var refuseStorage = false
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
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
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
    }
    private struct Libraries: OSDILibraryProviding {
        let ordinary: SPICEOSDILocalLibraryProvider
        let extra: SPICEOSDILocalLibraryProvider
        let extraReference: ArtifactReference
        func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
            if reference == extraReference { return try await extra.load(reference: reference, limits: limits) }
            return try await ordinary.load(reference: reference, limits: limits)
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
    private func devices(_ fixture: NativeGlobalChargeOSDIFixture, algebraicCapacitance: Double = 0,
        dynamic: Instance? = nil) throws -> [Instance] {
        try [Instance(name: "Vselected", typeName: "vsource", nodes: [p, .ground],
                parameters: ["v": .real(0)], ownedBranches: [branch]),
            dynamic ?? linear(fixture, name: "NQ", nodes: [z, p], conductance: 0, capacitance: 1),
            linear(fixture, name: "NG", nodes: [w, p], conductance: 1, capacitance: algebraicCapacitance),
            // Both raw charge rows/columns alias w and cancel; no caller zero flag is supplied.
            linear(fixture, name: "Nalias", nodes: [w, w], conductance: 0, capacitance: 1),
            Instance(name: "R1", typeName: "resistor", nodes: [w, z], parameters: ["r": .real(1)])]
    }
    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture, devices: [Instance], resources: Resources,
        provider: (any OSDILibraryProviding)? = nil) async throws -> PreparedNativeCircuit {
        let runtime = try SPICEOSDIRuntimeInputs(provider: provider ?? fixture.provider,
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
                let expected = foreign[i].osdi?.resolved.binding.expectedDescriptorName == "linear_rc"
                    ? "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203"
                    : "a7ffeffa20274b1a01d7f6fa2c9120dac70a00fa21ab621829892a8628bf23ae"
                try #require(programs[i].programDigest.hexadecimalValue == expected)
            }
            let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
            let wRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(w)])
            try #require(zRow < wRow)
        } catch { try owner.close(); throw error }
        return consume owner
    }
    private func values(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        positiveSlab: Bool = false) async throws -> NativePrescribedVoltageValues {
        let count = owner.plan.topology.dimension
        var lower = try [CompensatedValue](repeating: .init(high: 0), count: count)
        var upper = try [CompensatedValue](repeating: .init(high: 1.5), count: count)
        let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
        let wRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(w)])
        let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
        // Original D contains the outward-rounded slab without changing the candidate box.
        lower[zRow] = try .init(high: 0.25); upper[zRow] = try .init(high: 2)
        lower[wRow] = try .init(high: 0); upper[wRow] = try .init(high: 1.75)
        lower[iRow] = try .init(high: -10); upper[iRow] = try .init(high: 10)
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return try await owner.enclosePrescribedVoltageValues(
            originalDomain: .init(lower: lower, upper: upper, lowerContext: context, upperContext: context),
            sources: [.init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: 2,
                normalized: positiveSlab ? 0.25...0.3 : 0.25...0.5, leftSlope: 1...1, rightSlope: 2...2)],
            reducedCoordinates: positiveSlab ? [enclosure(0.7, 1.2), enclosure(0.5, 0.95)]
                : [enclosure(0.5, 1.75), enclosure(0.375, 1.5)],
            capture: fixture.capture, limits: valueLimits(), cancellation: .init())
    }
    private func certify(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        values: NativePrescribedVoltageValues, algebraicRows: [Int] = [1],
        charge: ClosedRange<Double> = 0.25...0.5, positiveSlab: Bool = false,
        cancellation: CancellationToken = .init()) async throws -> NativePrescribedVoltageChart {
        try await owner.certifyPrescribedVoltageChart(values: values, algebraicRows: algebraicRows,
            chargeParameters: [enclosure(charge.lowerBound, charge.upperBound)],
            center: positiveSlab ? [.init(high: 0.95), .init(high: 0.725)] : [.init(high: 1.125), .init(high: 0.9375)],
            inverse: SparseStructure(dimension: 2, rowPointers: [0, 1, 3], columnIndices: [0, 0, 1]),
            inverseValues: [1, 0.5, 0.5], capture: fixture.capture, range: range(fixture), limits: limits(), cancellation: cancellation)
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

    @Test func mixedActualChargeAndAlgebraicSourceCertifyEveryParameterAndRetainLease() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        var retained: NativePrescribedVoltageChart?
        do {
            let owner = try await prepare(fixture, devices: devices(fixture), resources: resources)
            do {
                let slab = try await values(owner, fixture)
                let baseline = resources.live + resources.temporary
                resources.arm(work: 0)
                await #expect(throws: Refusal.work) { try await certify(owner, fixture, values: slab) }
                resources.arm(storage: true)
                await #expect(throws: Refusal.storage) { try await certify(owner, fixture, values: slab) }
                resources.arm()
                let cancelled = CancellationToken(); cancelled.cancel()
                do { _ = try await certify(owner, fixture, values: slab, cancellation: cancelled)
                    Issue.record("Cancelled actual chart published") }
                catch NativeConstitutiveInspection.Failure.cancelled {}
                #expect(resources.live + resources.temporary == baseline)
                let chart = try await certify(owner, fixture, values: slab)
                #expect(chart.dimension == 2 && chart.chargeCoordinateCount == 1 && chart.algebraicCoordinateCount == 1)
                #expect(chart.sourceInputCount == 3 && chart.normUpperBound < 1e-10)
                #expect(try chart.chargeReducedRow(at: 0) == 0)
                #expect(try chart.algebraicReducedRow(at: 0) == 1)
                let dynamicImage = try chart.image(at: 0), algebraicImage = try chart.image(at: 1)
                for q in [0.25, 0.5] {
                    for phi in [0.5, 1.0] {
                        contains(dynamicImage, q + phi)
                        contains(algebraicImage, q / 2 + phi)
                    }
                }
                // Source-bound H=(z-phi-q,2w-z-phi), J=((1,0),(-1,2)).
                let dz = bounds(dynamicImage), aw = bounds(algebraicImage)
                #expect(dz.lowerBound > 0.5 && dz.upperBound < 1.75)
                #expect(aw.lowerBound > 0.375 && aw.upperBound < 1.5)
                retained = chart
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live > 0)
        do {
            let copy = try #require(retained)
            contains(try copy.image(at: 0), 1.5)
            retained = nil
            // The local copy intentionally keeps the immutable chart admission alive.
            #expect(resources.live > 0)
            withExtendedLifetime(copy) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func exactOwnerCapabilitiesAndWholeChargeParameterCellRemainRequired() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        do {
            let actualDevices = try devices(fixture)
            let owner = try await prepare(fixture, devices: actualDevices, resources: resources)
            do {
                let slab = try await values(owner, fixture), baseline = resources.live + resources.temporary
                do {
                    let other = try await prepare(fixture, devices: actualDevices, resources: resources)
                    do {
                        await #expect(throws: NativePrescribedVoltageChartFailure.wrongOwner) {
                            try await certify(other, fixture, values: slab)
                        }
                    } catch { try other.close(); throw error }
                    try other.close()
                }
                let q = try [enclosure(0.25, 0.5)]
                let center = try [CompensatedValue(high: 1.125), CompensatedValue(high: 0.9375)]
                let inverse = try SparseStructure(dimension: 2, rowPointers: [0, 1, 3], columnIndices: [0, 0, 1])
                await #expect(throws: NativePrescribedVoltageChartFailure.missingCaptureCapability) {
                    try await owner.certifyPrescribedVoltageChart(values: slab, algebraicRows: [1],
                        chargeParameters: q, center: center, inverse: inverse, inverseValues: [1, 0.5, 0.5],
                        capture: nil, range: range(fixture), limits: limits(), cancellation: .init())
                }
                await #expect(throws: NativePrescribedVoltageChartFailure.missingSmoothCapture) {
                    try await owner.certifyPrescribedVoltageChart(values: slab, algebraicRows: [1],
                        chargeParameters: q, center: center, inverse: inverse, inverseValues: [1, 0.5, 0.5],
                        capture: fixture.capture, range: nil, limits: limits(), cancellation: .init())
                }
                // The same well-formed source/J cannot certify roots outside the candidate voltage box.
                await #expect(throws: ValidatedParametricRoot.Failure.uncertified) {
                    try await certify(owner, fixture, values: slab, charge: 3...4)
                }
                #expect(resources.live + resources.temporary == baseline)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func changedActualCapacitanceAndWrongSelectorCannotBorrowPlausibleHJacobian() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        do {
            for changedCapacitance in [false, true] {
                let owner = try await prepare(fixture, devices: devices(fixture, algebraicCapacitance: changedCapacitance ? 1 : 0),
                    resources: resources)
                do {
                    let slab = try await values(owner, fixture), baseline = resources.live + resources.temporary
                    // NG G is unchanged and H/J proposal is unchanged when C0 becomes C1,
                    // but B*P*Q=w-phi is no longer an identity on the original domain.
                    do {
                        _ = try await certify(owner, fixture, values: slab, algebraicRows: changedCapacitance ? [1] : [0])
                        Issue.record("Actual nonzero charge row admitted as a strong null identity")
                    } catch OSDIConstitutiveCaptureFailure.control(let cause) {
                        guard case NativePrescribedVoltageChartFailure.unprovedNullRow = cause else { throw cause }
                    }
                    #expect(resources.live + resources.temporary == baseline)
                } catch { try owner.close(); throw error }
                try owner.close()
            }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func originalAbsSeamRefusesBeforeRootDespiteIdenticalPositiveCenterAndJacobian() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        let file = fixture.directory.appendingPathComponent("actual-chart-abs.osdi")
        do {
            do {
                let linearOwner = try await prepare(fixture, devices: devices(fixture), resources: resources)
                do {
                    let slab = try await values(linearOwner, fixture, positiveSlab: true)
                    let chart = try await certify(linearOwner, fixture, values: slab, positiveSlab: true)
                    for q in [0.25, 0.5] {
                        for phi in [0.5, 0.6] {
                            contains(try chart.image(at: 0), q + phi)
                            contains(try chart.image(at: 1), q / 2 + phi)
                        }
                    }
                    #expect(chart.normUpperBound < 1e-10)
                } catch { try linearOwner.close(); throw error }
                try linearOwner.close()
            }
            #expect(resources.live == 0 && resources.temporary == 0)
            let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_SMOOTH_NONSMOOTH_LIBRARY"])
            try FileManager.default.copyItem(atPath: path, toPath: file.path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                .init(location: ArtifactLocation(workspaceRelativePath: file.lastPathComponent), role: .input, kind: .model, format: .raw),
                relativeTo: fixture.directory)
            try #require(reference.digest.hexadecimalValue == "2abf2a2f59f8a40342fc8a8726f83d70c5ffdc8bf5e11f09eeb656357319927f")
            let intent = try ArtifactAccessIntent(expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: fixture.root.rootID,
                    relativePath: ArtifactRelativePath(segments: [file.lastPathComponent])), operation: .read,
                budget: .init(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            let extra = try SPICEOSDILocalLibraryProvider(rootID: fixture.root.rootID, directoryURL: fixture.directory,
                intents: [intent], stagingParentDirectory: fixture.directory, digester: SHA256ContentDigester())
            let binding = try OSDIModelBinding(modelName: "actual-chart-abs", artifact: reference, descriptorIndex: 0,
                expectedDescriptorName: "global_charge_nonsmooth", modelParameters: [])
            let dynamic = try Instance(name: "Nabs", typeName: "osdi", nodes: [z, p], parameters: [:],
                osdi: .resolved(OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])))
            let provider = Libraries(ordinary: fixture.provider, extra: extra, extraReference: reference)
            let owner = try await prepare(fixture, devices: devices(fixture, dynamic: dynamic), resources: resources, provider: provider)
            do {
                // The entire lifted slab has z-phi in [.1,.7], not just a sampled center.
                let slab = try await values(owner, fixture, positiveSlab: true)
                let baseline = resources.live + resources.temporary
                do {
                    _ = try await certify(owner, fixture, values: slab, positiveSlab: true)
                    Issue.record("Chart replaced original seam-crossing D with positive lifted slab")
                } catch OSDISmoothRangeFailure.runtime(.precision(let issue)) {
                    #expect(issue.code == .nonsmooth && issue.workerStatus == 10)
                }
                #expect(resources.live + resources.temporary == baseline)
            } catch { try owner.close(); throw error }
            try owner.close()
            try FileManager.default.removeItem(at: file)
        } catch {
            let primary = error
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try await fixture.close(); throw primary
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
