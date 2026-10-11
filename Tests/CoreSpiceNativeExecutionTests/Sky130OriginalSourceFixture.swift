import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceIO
import CoreSpiceMOSContracts
import Foundation
import Synchronization
import Testing

/// Original files enter through the same exact-catalog public API as host callers.
struct Sky130OriginalSourceFixture {
    let input: PreparedSPICESimulation
    let resources: ObservedResources
    let sourceBytes: UInt64
    let longestSourceKeyBytes: UInt64
    let resolutionWorkLimit: UInt64
    static let maximumPrograms = 100_000
    static let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10_000,
        maximumSolveAttempts: 100_000, maximumNewtonIterations: 1_000_000,
        maximumSavedScalars: 1_000_000, maximumMatrixDimension: 128,
        maximumWorkUnits: 1_000_000_000, maximumBreakpoints: 10_000)

    final class ObservedResources: SPICESourceResourceAccounting {
        let underlying: SPICESimulationResources
        private struct State {
            var work: [SPICESourceWorkKind: UInt64] = [:]
            var live: UInt64 = 0
            var temporary: UInt64 = 0
            var peakLive: UInt64 = 0
            var peakTemporary: UInt64 = 0
        }
        private let state = Mutex(State())
        init() throws {
            underlying = try .init(maximumLiveBytes: 2_000_000_000,
                maximumTemporaryBytes: 1_000_000_000, maximumWorkUnits: 10_000_000_000,
                maximumHashedBytes: 64_000_000)
        }
        func checkCancellation() throws { try underlying.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try underlying.charge(kind, units: units)
            state.withLock { $0.work[kind, default: 0] += units }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws { try underlying.chargeHashedBytes(bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            let receipt = try underlying.reserveStorage(kind: kind, byteCount: byteCount)
            state.withLock {
                if kind == .liveOwnedBytes { $0.live += byteCount; $0.peakLive = max($0.peakLive, $0.live) }
                else { $0.temporary += byteCount; $0.peakTemporary = max($0.peakTemporary, $0.temporary) }
            }
            return .init(kind: kind, byteCount: byteCount) { [self, receipt] in
                state.withLock {
                    if kind == .liveOwnedBytes { $0.live -= byteCount }
                    else { $0.temporary -= byteCount }
                }
                withExtendedLifetime(receipt) {}
            }
        }
        var observedWork: [String: UInt64] {
            state.withLock { Dictionary(uniqueKeysWithValues: $0.work.map { ($0.key.rawValue, $0.value) }) }
        }
        var capacities: [String: UInt64] {
            state.withLock { ["live": $0.live, "temporary": $0.temporary,
                "peakLive": $0.peakLive, "peakTemporary": $0.peakTemporary] }
        }
    }
    private struct Provider: SPICEExactSourceProviding {
        let sources: [SPICECheckedSource]
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            try #require(sources.first { $0.binding == binding })
        }
    }
    private static func capture(_ data: Data, key: String, resources: ObservedResources) throws -> SPICECheckedSource {
        let bytes = Array(data)
        let hash = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: key, reference: try ArtifactReference(digest: hash.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        return try .admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 65536)
    }
    static func prepare(root: String, files: [String], entries: [String]? = nil, deck: String,
                        routes: [SPICESourceCatalogRoute] = []) async throws -> Self {
        let resources = try ObservedResources()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("libs.ref/sky130_fd_pr/spice")
        let reader = LocalSPICESourceReader()
        var sources: [SPICECheckedSource] = []
        for file in files {
            sources.append(try capture(reader.read(at: directory.appendingPathComponent(file).path,
                maximumByteCount: 2_000_000, maximumPageByteCount: 65536), key: file, resources: resources))
        }
        let caller = try capture(Data(deck.utf8), key: "sky130-original-caller", resources: resources)
        let admitted = [caller] + sources
        let sourceBytes = admitted.reduce(UInt64(0)) { $0 + $1.binding.reference.byteCount }
        let longest = UInt64(admitted.map { $0.binding.key.utf8.count }.max() ?? 0)
        // Three coordinate keys per program plus sixteen source-sized passes: explicit caller headroom.
        let work = 3 * longest * UInt64(maximumPrograms) + 16 * sourceBytes
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "original-sky130-v1",
            configuration: configuration, resources: resources, maximumPageByteCount: 65536)
        let resolution = try MOSResolutionLimits(maximumRetainedBytes: 512_000_000,
            maximumDiagnosticBytes: 1_000_000, maximumScopeDepth: 32, maximumSymbols: 8192,
            maximumScopes: 32, maximumInvocations: 64, maximumInvocationBindings: 8192,
            maximumDeclarations: 256, maximumPrograms: maximumPrograms, maximumBindings: 8192,
            maximumFunctions: 64, maximumFunctionDepth: 32, maximumExpressionNodes: 512,
            maximumExpressionDepth: 128, maximumCandidates: 256, maximumCacheEntries: 200_000,
            maximumEvaluationSteps: work)
        let rootRoutes = (entries ?? files).map { SPICESourceCatalogRoute(parentKey: caller.binding.key,
            childKey: $0, literalRoute: $0, kind: .include) }
        let input = try await SPICESimulationPreparer().prepare(.init(root: caller, environment: environment,
            catalog: admitted.map(\.binding), routes: rootRoutes + routes, provider: Provider(sources: sources),
            configuration: configuration, operatingPolicy: .recordActual,
            limits: .init(maximumElements: 8192, maximumTransformBytes: 512_000_000,
                maximumSweepPoints: 8, maximumPageByteCount: 65536, numerical: numerical),
            profile: .pinnedNgspiceNormalV1, seed: 42, resolutionLimits: resolution), resources: resources)
        return Self(input: input, resources: resources, sourceBytes: sourceBytes,
            longestSourceKeyBytes: longest, resolutionWorkLimit: work)
    }
    func prepareNative(capabilities: MOSAnalysisCapabilities, constantGateForFiniteDifference: Bool = false) throws -> PreparedNativeCircuit {
        var circuit = input.circuit
        if constantGateForFiniteDifference {
            // Independent DC perturbations replace only the caller source; original MOS results stay identical.
            let instances = circuit.instances.map { instance in
                guard instance.name.lowercased() == "vg" else { return instance }
                return Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                    parameters: ["v": .real(1.2)], model: instance.model, mos: instance.mos,
                    modelConsumption: instance.modelConsumption, ownedNodes: instance.ownedNodes,
                    ownedBranches: instance.ownedBranches, referencedBranches: instance.referencedBranches,
                    referencedNodes: instance.referencedNodes, opticalNodes: instance.opticalNodes)
            }
            circuit = CircuitIR(nodes: circuit.nodes, branches: circuit.branches, instances: instances,
                groundNode: circuit.groundNode, nodeNames: circuit.nodeNames, branchNames: circuit.branchNames,
                opticalNodes: circuit.opticalNodes, opticalConnections: circuit.opticalConnections)
        }
        let operating = try input.configuration.options.operatingConditions()
        return try NativeCircuitPreparer().prepare(ir: circuit, registry: .standard(),
            operatingConditions: operating, limits: .init(maximumDeviceCount: 64, maximumMatrixDimension: 128,
                maximumAllocationBytes: 32_000_000,
                mosPreparationLimits: try .init(maximumRetainedBytes: 2_000_000,
                    maximumTemporaryBytes: 1_000_000, maximumDiagnosticBytes: 64_000, maximumWorkUnits: 1_000_000),
                mosPreparationConditions: try .init(ambientKelvin: operating.temperatureKelvin,
                    nominalKelvin: operating.nominalTemperatureKelvin, analysisCapabilities: capabilities,
                    maximumStressIterations: 64)), numericalLimits: Self.numerical, resources: resources)
    }
}
