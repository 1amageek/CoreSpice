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
import Testing
@testable import CoreSpice

@Suite("Actual-source conditional initial covers", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageInitialCoverOSDITests {
    typealias E = CompensatedEnclosure
    typealias N = NativePrescribedVoltageInitialCoverProposal.Node
    let helpers = NativePrescribedVoltageInitialCoverTests()
    let w = Node(id: 1)
    struct Polynomial {
        let directory: URL
        let provider: SPICEOSDILocalLibraryProvider
        let reference: ArtifactReference
        init() throws {
            let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_INITIAL_COVER_POLYNOMIAL_LIBRARY"])
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("initial-cover-polynomial-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.copyItem(atPath: path, toPath: directory.appendingPathComponent("polynomial.osdi").path)
            let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
            reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "polynomial.osdi"), role: .input, kind: .model, format: .raw), relativeTo: directory)
            try #require(reference.digest.hexadecimalValue == "566f89175f9b59ee572b7243db48331f3657f80c54f36dd3118738a09782ae7a")
            let intent = try ArtifactAccessIntent(expectedReference: reference,
                availability: .local(artifactID: reference.id, rootID: rootID, relativePath: ArtifactRelativePath(segments: ["polynomial.osdi"])),
                operation: .read, budget: .init(maximumPageByteCount: 65_536, maximumTotalByteCount: 16_777_216,
                    maximumPageCount: 4096, maximumWorkUnitCount: 8192, maximumDurationNanoseconds: 5_000_000_000))
            provider = try .init(rootID: rootID, directoryURL: directory, intents: [intent], stagingParentDirectory: directory,
                digester: SHA256ContentDigester())
        }
        func close() throws { try FileManager.default.removeItem(at: directory) }
    }
    func enclosure(_ lower: Double, _ upper: Double) throws -> E {
        try .init(center: .init(high: lower / 2 + upper / 2), radius: (upper - lower) / 2)
    }
    func prepare(_ fixture: NativeGlobalChargeOSDIFixture, _ polynomial: Polynomial,
        resources: NativePrescribedVoltageInitialCoverTests.Resources) async throws -> PreparedNativeCircuit {
        let binding = try OSDIModelBinding(modelName: "polynomial", artifact: polynomial.reference, descriptorIndex: 0,
            expectedDescriptorName: "initial_cover_polynomial", modelParameters: [])
        let instance = try Instance(name: "Npoly", typeName: "osdi", nodes: [w], parameters: [:],
            osdi: .resolved(OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])))
        let runtime = try SPICEOSDIRuntimeInputs(provider: polynomial.provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 1,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let owner = try await NativeCircuitPreparer().prepare(ir: CircuitIR(nodes: [.ground,w], branches: [], instances: [instance]),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15), limits: fixture.nativeLimits,
            numericalLimits: fixture.numerical, resources: resources, osdi: runtime, constitutive: fixture.snapshot, cancellation: .init())
        do {
            let program = try #require(owner.record.constitutiveBacking?.programs.first)
            try #require(program.modelReference == polynomial.reference)
            try #require(program.programDigest.hexadecimalValue == "c914f4a82cb431ddebc715c7b0f9686b17de9d6c5916bc3d249f413a3d5f04b4")
            try #require(program.topology.nodes.count == 1 && program.topology.activeUnknownCount == 1)
        } catch { try owner.close(); throw error }
        return consume owner
    }
    func values(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        d: ClosedRange<Double>, z: ClosedRange<Double>) async throws -> NativePrescribedVoltageValues {
        try await owner.enclosePrescribedVoltageValues(originalDomain: helpers.domain([d.lowerBound],[d.upperBound]), sources: [],
            reducedCoordinates: [enclosure(z.lowerBound,z.upperBound)], capture: fixture.capture,
            limits: helpers.limits(retained: 1_048_576), cancellation: .init())
    }
    func root(_ owner: borrowing PreparedNativeCircuit, _ fixture: NativeGlobalChargeOSDIFixture,
        negative: Bool) async throws -> NativePrescribedVoltageInitialRoot {
        let v = try await values(owner, fixture, d: negative ? -1.75 ... -0.25 : 0.25...1.75,
            z: negative ? -1.5 ... -0.5 : 0.5...1.5)
        let range = OSDISmoothRangeCaptureInputs(preparer: OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory),
            worker: fixture.capture.worker, source: fixture.capture.source, numericProfile: fixture.capture.numericProfile,
            options: fixture.capture.options)
        return try await owner.certifyPrescribedVoltageInitialRoot(values: v, algebraicRows: [0], dynamicInitialCoordinates: [],
            center: [.init(high: negative ? -1 : 1)], inverse: SparseStructure(dimension: 1, rowPointers: [0,1], columnIndices: [0]),
            inverseValues: [negative ? -0.5 : 0.5], capture: fixture.capture, range: range,
            limits: helpers.chartLimits(), cancellation: .init())
    }
    func check(_ owner: borrowing PreparedNativeCircuit, _ structure: NativePrescribedVoltageInitialStructure,
        lower: Double = -2, upper: Double = 2, nodes: [N]) throws -> NativePrescribedVoltageInitialCover {
        try helpers.check(owner, structure, lower: [lower], upper: [upper], u: [], nodes: nodes)
    }
    @Test func bothSameParameterBranchesAndStrictSourceExclusionsAreRequired() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), polynomial = try Polynomial()
        let resources = NativePrescribedVoltageInitialCoverTests.Resources()
        do {
            let owner = try await prepare(fixture, polynomial, resources: resources)
            let full = try await values(owner, fixture, d: -3...3, z: -2.25...2.25)
            let structure = try await owner.preparePrescribedVoltageInitialStructure(values: full, algebraicRows: [0],
                capture: fixture.capture, limits: helpers.chartLimits(), cancellation: .init())
            let minus = try await root(owner, fixture, negative: true), plus = try await root(owner, fixture, negative: false)
            helpers.contains(try minus.image(at: 0), -1); helpers.contains(try plus.image(at: 0), 1)
            let left = try await values(owner, fixture, d: -3...3, z: -2.125 ... -1.1875)
            let middle = try await values(owner, fixture, d: -3...3, z: -0.8125...0.8125)
            let right = try await values(owner, fixture, d: -3...3, z: 1.1875...2.125)
            let nodes: [N] = try [.split(axis: 0, at: helpers.endpoint(0), left: 1, right: 6),
                .split(axis: 0, at: helpers.endpoint(-1.25), left: 2, right: 3),
                .excluded(values: left, component: 0),
                .split(axis: 0, at: helpers.endpoint(-0.75), left: 4, right: 5), .included(minus),
                .excluded(values: middle, component: 0),
                .split(axis: 0, at: helpers.endpoint(0.75), left: 7, right: 8), .excluded(values: middle, component: 0),
                .split(axis: 0, at: helpers.endpoint(1.25), left: 9, right: 10), .included(plus), .excluded(values: right, component: 0)]
            let result = try check(owner, structure, nodes: nodes)
            #expect(result.isComplete && result.includedLeafCount == 2 && result.excludedLeafCount == 4)
            var missing = nodes; missing[4] = .unresolved
            #expect(try !check(owner, structure, nodes: missing).isComplete)
            var wrong = nodes; wrong[4] = .included(plus)
            do { _ = try check(owner, structure, nodes: wrong); Issue.record("Positive root hid the negative root at the same parameter") }
            catch NativePrescribedVoltageInitialCoverFailure.insufficientWitness {}
            do { _ = try check(owner, structure, nodes: [.included(plus)]); Issue.record("A local positive root covered both branches") }
            catch NativePrescribedVoltageInitialCoverFailure.insufficientWitness {}
            let boundary = try check(owner, structure, lower: -1.25, upper: -0.75,
                nodes: [.split(axis: 0, at: helpers.endpoint(-1), left: 1, right: 2), .included(minus), .included(minus)])
            #expect(boundary.isComplete && boundary.includedLeafCount == 2)
            let empty = try check(owner, structure, lower: -0.5, upper: 0.5, nodes: [.excluded(values: middle, component: 0)])
            #expect(empty.isProvedEmpty)
            let zero = try await values(owner, fixture, d: -3...3, z: 1...1)
            do { _ = try check(owner, structure, lower: 1, upper: 1, nodes: [.excluded(values: zero, component: 0)]); Issue.record("Zero source residual was strict exclusion") }
            catch NativePrescribedVoltageInitialCoverFailure.insufficientWitness {}
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        try polynomial.close(); try await fixture.close()
    }
    @Test func originalLinearAndParabolaFixturesKeepTheirActualStrongPlaneMeaning() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = NativePrescribedVoltageInitialCoverTests.Resources()
        do {
            let linear = try fixture.instance("Nlinear", nodes: [w,.ground], capacitance: 0)
            let owner = try await fixture.prepare([linear], nodes: [.ground,w], resources: resources)
            let v = try await owner.enclosePrescribedVoltageValues(originalDomain: helpers.domain([-3],[3]), sources: [],
                reducedCoordinates: [enclosure(-2,2)], capture: fixture.capture, limits: helpers.limits(), cancellation: .init())
            let structure = try await owner.preparePrescribedVoltageInitialStructure(values: v, algebraicRows: [0],
                capture: fixture.capture, limits: helpers.chartLimits(), cancellation: .init())
            let pending = try check(owner, structure, nodes: [.unresolved])
            #expect(!pending.isComplete)
            try owner.close()
        }
        do {
            let nonlinear = try fixture.instance("Nparabola", nodes: [w,.ground], capacitance: nil)
            let owner = try await fixture.prepare([nonlinear], nodes: [.ground,w], resources: resources)
            let v = try await owner.enclosePrescribedVoltageValues(originalDomain: helpers.domain([-2],[2]), sources: [],
                reducedCoordinates: [enclosure(-1,1)], capture: fixture.capture, limits: helpers.limits(), cancellation: .init())
            do {
                _ = try await owner.preparePrescribedVoltageInitialStructure(values: v, algebraicRows: [0],
                    capture: fixture.capture, limits: helpers.chartLimits(), cancellation: .init())
                Issue.record("Nonzero parabola charge acquired a strong algebraic plane")
            } catch OSDIConstitutiveCaptureFailure.control(let cause) {
                guard case NativePrescribedVoltageChartFailure.unprovedNullRow = cause else { throw cause }
            }
            try owner.close()
        }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
