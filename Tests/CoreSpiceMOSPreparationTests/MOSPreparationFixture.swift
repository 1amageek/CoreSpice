import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Synchronization

struct MOSPreparationFixture {
    static func resolve(_ release: MOSModelRelease = .level1, polarity: MOSPolarity = .nmos,
                        model: [(String, Double)] = [], instance: [(String, Double)] = []) throws -> ResolvedMOSInstance {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 8_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 256, maximumScopes: 16, maximumInvocations: 16,
            maximumInvocationBindings: 128, maximumDeclarations: 64, maximumPrograms: 256,
            maximumBindings: 256, maximumFunctions: 16, maximumFunctionDepth: 16,
            maximumExpressionNodes: 256, maximumExpressionDepth: 64, maximumCandidates: 64,
            maximumCacheEntries: 256, maximumEvaluationSteps: 100_000)
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let scope = try builder.addScope(parent: nil), reference = try builder.intern("model")
        var coefficients: [MOSExpressionBinding] = []
        for (name, value) in model {
            coefficients.append(try MOSExpressionBinding(symbol: builder.intern(name), program: builder.addProgram(.literal(value))))
        }
        let source = MOSSourceOccurrence(captureID: "fixture", occurrenceID: 1, path: "fixture.sp",
            line: 1, column: 1, statementByteOffset: 0, statementOrdinal: 0)
        _ = try builder.addModel(name: "model", scope: scope, polarity: polarity, level: release.level,
            version: release.exactVersion, coefficients: coefficients, source: source)
        var bindings: [MOSExpressionBinding] = []
        for (name, value) in instance {
            bindings.append(try MOSExpressionBinding(symbol: builder.intern(name), program: builder.addProgram(.literal(value))))
        }
        let snapshot = try builder.finish()
        let invocation = try MOSScopeInvocation(id: 1, scope: scope, callerInvocationID: nil, actuals: [], limits: limits)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [invocation], limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        let request = try MOSResolutionRequest(instance: "M1", scope: scope, scopeInstantiation: 1,
            modelReference: reference, profile: .coreStrictV1, bindings: bindings, geometryScale: 1,
            seed: 1, limits: limits)
        return try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
    }

    static func conditions(ambient: Double = 300.15, nominal: Double = 300.15,
                           capabilities: MOSAnalysisCapabilities = [.dc, .ac, .transient]) throws -> MOSPreparationConditions {
        try MOSPreparationConditions(ambientKelvin: ambient, nominalKelvin: nominal,
            analysisCapabilities: capabilities)
    }

    static func limits(bytes: UInt64 = 8_000_000, temporary: UInt64 = 8_000_000, work: UInt64 = 100_000) throws -> MOSPreparationLimits {
        try MOSPreparationLimits(maximumRetainedBytes: bytes, maximumTemporaryBytes: temporary,
            maximumDiagnosticBytes: 1_000_000, maximumWorkUnits: work)
    }

    static func instance(_ receipt: MOSPreparationReceipt, ports: [Node]? = nil) -> Instance {
        let prefix = receipt.identity.resolved.polarity == .nmos ? "nmos" : "pmos"
        return Instance(name: "M1", typeName: "\(prefix)_l\(receipt.identity.resolved.release.level)",
            nodes: ports ?? (1...4).map { Node(id: $0) }, parameters: [:], mos: .prepared(receipt))
    }

    static func context(_ instance: Instance, ambient: Double = 300.15, nominal: Double = 300.15,
                        csr: Bool = true) throws -> BindingContext {
        var variables: [MNAVariable: Int] = [:]
        for node in instance.nodes where node != .ground {
            if variables[.nodeVoltage(node)] == nil { variables[.nodeVoltage(node)] = variables.count }
        }
        let dimension = variables.count
        let full: @Sendable (Int, Int) -> Int? = { $0 * dimension + $1 }
        return BindingContext(variableMap: variables, matrixDimension: dimension,
            operatingConditions: try OperatingConditions(temperatureKelvin: ambient, nominalTemperatureKelvin: nominal),
            stampIndexResolver: csr ? full : nil)
    }
}

final class MOSPreparationTestControl: MOSPreparationControlling {
    private struct State { var checks = 0; var work: UInt64 = 0; var cancelled = false }
    private let state = Mutex(State())
    let cancelAfter: Int?
    init(cancelAfter: Int? = nil) { self.cancelAfter = cancelAfter }
    func cancel() { state.withLock { $0.cancelled = true } }
    func checkCancellation() throws(MOSPreparationFailure) {
        try state.withLock { state throws(MOSPreparationFailure) in
            state.checks += 1
            if state.cancelled || cancelAfter.map({ state.checks >= $0 }) == true { throw .cancelled }
        }
    }
    func chargeWork(units: UInt64) throws(MOSPreparationFailure) { state.withLock { $0.work += units } }
    var work: UInt64 { state.withLock { $0.work } }
}
