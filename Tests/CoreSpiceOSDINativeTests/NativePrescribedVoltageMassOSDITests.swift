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

@Suite("Actual OSDI mass on the original domain", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageMassOSDITests {
    private typealias E = CompensatedEnclosure
    private enum Refusal: Error, Equatable { case work, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var remaining: UInt64?
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        func arm(work: UInt64? = nil) { state.withLock { $0.remaining = work } }
        func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                if let remaining = value.remaining {
                    guard units <= remaining else { throw Refusal.work }
                    value.remaining = remaining - units
                }
                guard units <= 8_000_000_000 - value.work else { throw Refusal.work }
                value.work += units
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try charge(.retainedElements, units: bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            try state.withLock { value in
                let current = kind == .liveOwnedBytes ? value.live : value.temporary
                guard byteCount <= 536_870_912 - current else { throw Refusal.storage }
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
    private func massLimits() -> NativePrescribedVoltageMassLimits {
        .init(maximumTriplets: 64, maximumRetainedBytes: 1_048_576,
            maximumWorkspaceBytes: 1_048_576, precisionBits: 192)
    }
    private func regularityLimits() -> ValidatedMatrixRegularity.Limits {
        .init(maximumDimension: 8, maximumMatrixNonzeros: 64,
            maximumInverseNonzeros: 64, maximumWorkspaceBytes: 1_048_576)
    }
    private func range(_ fixture: NativeGlobalChargeOSDIFixture) -> OSDISmoothRangeCaptureInputs {
        .init(preparer: OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory),
            worker: fixture.capture.worker, source: fixture.capture.source,
            numericProfile: fixture.capture.numericProfile, options: fixture.capture.options)
    }
    private func voltage(_ p: Node, branch: Branch) -> Instance {
        .init(name: "Vselected", typeName: "vsource", nodes: [p, .ground],
            parameters: ["v": .real(0)], ownedBranches: [branch])
    }
    private func resistor(_ z: Node) -> Instance {
        .init(name: "R4", typeName: "resistor", nodes: [z, .ground], parameters: ["r": .real(4)])
    }
    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture, devices: [Instance], nodes: [Node], branch: Branch,
        resources: Resources, provider: SPICEOSDILocalLibraryProvider? = nil) async throws -> PreparedNativeCircuit {
        let runtime = try SPICEOSDIRuntimeInputs(provider: provider ?? fixture.provider,
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
            for i in programs.indices {
                try #require(programs[i].modelReference == foreign[i].osdi?.resolved.binding.artifact)
                let expected: String
                switch foreign[i].osdi?.resolved.binding.expectedDescriptorName {
                case "linear_rc": expected = "2dd3c8f0a814583b8c6118825393a350f4e2f64d112a6a53060aeba20bf4b203"
                case "global_charge_parabola": expected = "22bf1ebc619fcf7473d5845ad970638ef9a3a3123a8592b50538f522ebebc205"
                case "global_charge_nonsmooth": expected = "a7ffeffa20274b1a01d7f6fa2c9120dac70a00fa21ab621829892a8628bf23ae"
                default: throw OSDISmoothRangeFailure.invalidBinding
                }
                try #require(programs[i].programDigest.hexadecimalValue == expected)
            }
        } catch { try owner.close(); throw error }
        return consume owner
    }
    private func image(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        z: Node, branch: Branch, originalZ: ClosedRange<Double>) async throws -> NativePrescribedVoltageValues {
        let count = owner.plan.topology.dimension
        let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
        let iRow = try #require(owner.plan.topology.variableMap[.branchCurrent(branch)])
        var lower = try [CompensatedValue](repeating: .init(high: -2), count: count)
        var upper = try [CompensatedValue](repeating: .init(high: 2), count: count)
        lower[zRow] = try .init(high: originalZ.lowerBound); upper[zRow] = try .init(high: originalZ.upperBound)
        lower[iRow] = try .init(high: -10); upper[iRow] = try .init(high: 10)
        let context = try OSDIPrecisionContext(mode: .transient, timeHigh: 0.25, timeLow: 0)
        return try await owner.enclosePrescribedVoltageValues(
            originalDomain: .init(lower: lower, upper: upper, lowerContext: context, upperContext: context),
            sources: [.init(deviceIndex: 0, zeroVoltage: 0, oneVoltage: 2, timeOrigin: 0, timeScale: 2,
                normalized: 0.5...0.5, leftSlope: 1...1, rightSlope: 2...2)],
            reducedCoordinates: [scalar(0.5)], capture: fixture.capture,
            limits: .init(maximumNativeTerms: 32, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576,
                precisionBits: 192, reductionLimits: .init(maximumAxes: 8, maximumSources: 2,
                    maximumWorkspaceBytes: 1_048_576, maximumResultBytes: 1_048_576)), cancellation: .init())
    }
    private func contains(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let bounds = value.center.bounds
        #expect((bounds.lower - value.radius).nextDown <= expected
            && (bounds.upper + value.radius).nextUp >= expected, sourceLocation: sourceLocation)
    }
    private func tight(_ value: E, _ expected: Double, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        contains(value, expected, sourceLocation: sourceLocation)
        #expect(abs(value.center.high - expected + value.center.low) + value.radius < 1e-10, sourceLocation: sourceLocation)
    }

    @Test func signedActualInstancesMustCoalesceBeforeRegularityAndRetainOriginalControl() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        let z = Node(id: 1), p = Node(id: 2), branch = Branch(id: 0)
        do {
            for second in [1.0, -1.0] {
                let devices = [voltage(p, branch: branch), try fixture.instance("N1", nodes: [z, .ground]),
                    try fixture.instance("N2", nodes: [z, .ground], capacitance: second), resistor(z)]
                let owner = try await prepare(fixture, devices: devices, nodes: [.ground, z, p], branch: branch, resources: resources)
                do {
                    let values = try await image(owner, fixture, z: z, branch: branch, originalZ: -1...1)
                    let baseline = resources.live + resources.temporary
                    if second > 0 {
                        resources.arm(work: 0)
                        await #expect(throws: Refusal.work) {
                            try await owner.assemblePrescribedVoltageMass(values: values, range: range(fixture),
                                limits: massLimits(), cancellation: .init())
                        }
                        resources.arm()
                        let cancellation = CancellationToken(); cancellation.cancel()
                        do {
                            _ = try await owner.assemblePrescribedVoltageMass(values: values, range: range(fixture),
                                limits: massLimits(), cancellation: cancellation)
                            Issue.record("Cancelled actual mass published")
                        } catch NativeConstitutiveInspection.Failure.cancelled {}
                        #expect(resources.live + resources.temporary == baseline)
                    }
                    let mass = try await owner.assemblePrescribedVoltageMass(values: values, range: range(fixture),
                        limits: massLimits(), cancellation: .init())
                    try mass.withMatrix { dimension, rows, columns, coefficients in
                        #expect(dimension == 1 && rows.count == 2 && rows[0] == 0)
                        if second > 0 {
                            try #require(coefficients.count == 1 && columns.count == 1 && rows[1] == 1)
                            #expect(columns[0] == 0)
                            // R=.5 could also certify the wrong first-instance M=1; inspect M=2 directly.
                            tight(coefficients[0], 2)
                        } else {
                            #expect(coefficients.count <= 1 && rows[1] == coefficients.count)
                            if coefficients.count == 1 { #expect(columns[0] == 0); tight(coefficients[0], 0) }
                        }
                    }
                    for side in [NativePrescribedVoltageReconstruction.Side.left, .right] {
                        tight(try mass.drift(at: 0, side: side), 0.125)
                    }
                    let inverse = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0]), r = [0.5]
                    if second > 0 {
                        let regularity = try mass.certifyRegularity(inverse: inverse, inverseValues: r.span,
                            limits: regularityLimits(), cancellation: .init())
                        #expect(regularity.dimension == 1 && regularity.normUpperBound < 1e-10)
                        try owner.close()
                        mass.withMatrix { _, _, _, coefficients in tight(coefficients[0], 2) }
                        #expect(regularity.dimension == 1 && resources.live > 0)
                    } else {
                        #expect(throws: ValidatedMatrixRegularity.Failure.uncertified) {
                            try mass.certifyRegularity(inverse: inverse, inverseValues: r.span,
                                limits: regularityLimits(), cancellation: .init())
                        }
                        try owner.close()
                    }
                } catch { try owner.close(); throw error }
            }
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func aliasedRawRowsAndColumnsSumOnOriginalDomainWithGroundRetainedUntilProjection() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        let z = Node(id: 1), p = Node(id: 2), branch = Branch(id: 0)
        do {
            let owner = try await prepare(fixture, devices: [voltage(p, branch: branch),
                fixture.instance("Nalias", nodes: [z, z], capacitance: nil), resistor(z)],
                nodes: [.ground, z, p], branch: branch, resources: resources)
            do {
                let values = try await image(owner, fixture, z: z, branch: branch, originalZ: 0.25...0.75)
                let mass = try await owner.assemblePrescribedVoltageMass(values: values, range: range(fixture),
                    limits: massLimits(), cancellation: .init())
                try mass.withMatrix { dimension, rows, columns, coefficients in
                    try #require(dimension == 1 && rows.count == 2 && rows[0] == 0 && rows[1] == 1)
                    try #require(columns.count == 1 && coefficients.count == 1)
                    #expect(columns[0] == 0)
                    // Both raw outputs map to z: Q=z+z^2, so C=1+2z over ORIGINAL [.25,.75].
                    contains(coefficients[0], 1.5); contains(coefficients[0], 2.5)
                    #expect(coefficients[0].radius >= 0.5 && coefficients[0].radius < 0.5000000001)
                }
                let inverse = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0]), r = [0.5]
                let regularity = try mass.certifyRegularity(inverse: inverse, inverseValues: r.span,
                    limits: regularityLimits(), cancellation: .init())
                #expect(regularity.dimension == 1 && regularity.normUpperBound < 0.251)
                tight(try mass.drift(at: 0, side: .left), 0.125)
                tight(try mass.drift(at: 0, side: .right), 0.125)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func freeAbsChargeOriginalDomainCannotBeReplacedByPositiveValuesSlab() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = Resources()
        let z = Node(id: 1), p = Node(id: 2), branch = Branch(id: 0)
        let file = fixture.directory.appendingPathComponent("actual-nonsmooth.osdi")
        do {
            let source = try #require(ProcessInfo.processInfo.environment["CORESPICE_SMOOTH_NONSMOOTH_LIBRARY"])
            try FileManager.default.copyItem(atPath: source, toPath: file.path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                .init(location: ArtifactLocation(workspaceRelativePath: file.lastPathComponent), role: .input, kind: .model, format: .raw),
                relativeTo: fixture.directory)
            try #require(reference.digest.hexadecimalValue == "2abf2a2f59f8a40342fc8a8726f83d70c5ffdc8bf5e11f09eeb656357319927f")
            let intent = try ArtifactAccessIntent(expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: fixture.root.rootID,
                    relativePath: ArtifactRelativePath(segments: [file.lastPathComponent])), operation: .read,
                budget: .init(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            let provider = try SPICEOSDILocalLibraryProvider(rootID: fixture.root.rootID, directoryURL: fixture.directory,
                intents: [intent], stagingParentDirectory: fixture.directory, digester: SHA256ContentDigester())
            let binding = try OSDIModelBinding(modelName: "actual-abs", artifact: reference, descriptorIndex: 0,
                expectedDescriptorName: "global_charge_nonsmooth", modelParameters: [])
            let abs = try Instance(name: "Nabs", typeName: "osdi", nodes: [z, .ground], parameters: [:],
                osdi: .resolved(OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])))
            let owner = try await prepare(fixture, devices: [voltage(p, branch: branch), abs, resistor(z)],
                nodes: [.ground, z, p], branch: branch, resources: resources, provider: provider)
            do {
                // Same true source first succeeds on the positive lifted Values slab z=.5.
                let values = try await image(owner, fixture, z: z, branch: branch, originalZ: -1...1)
                let zRow = try #require(owner.plan.topology.variableMap[.nodeVoltage(z)])
                tight(try values.charge(at: zRow), 0.5)
                let baseline = resources.live + resources.temporary
                do {
                    _ = try await owner.assemblePrescribedVoltageMass(values: values, range: range(fixture),
                        limits: massLimits(), cancellation: .init())
                    Issue.record("Mass used positive slab instead of original D crossing the abs face")
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
            try await fixture.close()
            throw primary
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
