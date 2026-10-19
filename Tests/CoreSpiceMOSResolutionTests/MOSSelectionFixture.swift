import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

struct MOSSelectionFixture: ~Copyable {
    let limits: MOSResolutionLimits
    var builder: MOSDeclarationSnapshotBuilder
    let root: MOSScopeID
    let model: MOSSymbolID
    let l: MOSSymbolID
    let w: MOSSymbolID
    private var didFinish = false
    init() throws {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 8_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 32, maximumSymbols: 256, maximumScopes: 32,
            maximumInvocations: 64, maximumInvocationBindings: 512, maximumDeclarations: 128,
            maximumPrograms: 256, maximumBindings: 256, maximumFunctions: 32, maximumFunctionDepth: 32,
            maximumExpressionNodes: 256, maximumExpressionDepth: 128, maximumCandidates: 128,
            maximumCacheEntries: 256, maximumEvaluationSteps: 1_000_000)
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil)
        let model = try builder.intern("n")
        let l = try builder.intern("l"), w = try builder.intern("w")
        self.limits = limits
        self.builder = consume builder
        self.root = root; self.model = model
        self.l = l; self.w = w
    }
    mutating func binding(_ name: String, _ value: Double) throws -> MOSExpressionBinding {
        guard !didFinish else { throw MOSResolutionFailure.invalidRequest }
        let symbol = try builder.intern(name)
        let program = try builder.addProgram(.literal(value))
        return MOSExpressionBinding(symbol: symbol, program: program)
    }
    mutating func model(_ name: String, scope: MOSScopeID? = nil,
        level: Int? = 1, version: String? = nil) throws -> MOSDeclarationID {
        guard !didFinish else { throw MOSResolutionFailure.invalidRequest }
        return try builder.addModel(name: name, scope: scope ?? root, polarity: .nmos,
            level: level, version: version, coefficients: [], source: Self.source(name))
    }
    mutating func finish() throws -> MOSDeclarationSnapshot {
        guard !didFinish else { throw MOSResolutionFailure.invalidRequest }
        didFinish = true
        var owned = MOSDeclarationSnapshotBuilder(limits: limits)
        // Restore the construction slot so immutable request metadata remains borrowable after publication.
        // Construction helpers refuse further use; this replacement supplies no IDs to the published snapshot.
        swap(&owned, &builder)
        return try owned.finish()
    }
    static func source(_ path: String) -> MOSSourceOccurrence {
        MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: path, line: 1, column: 1,
            statementByteOffset: nil, statementOrdinal: nil)
    }
    func graph(_ snapshot: MOSDeclarationSnapshot, invocations: [MOSScopeInvocation]? = nil) throws -> MOSInvocationGraph {
        try MOSInvocationGraph(snapshot: snapshot, invocations: invocations ?? [
            try MOSScopeInvocation(id: 1, scope: root, callerInvocationID: nil, actuals: [], limits: limits)
        ], limits: limits)
    }
    func request(_ values: [MOSExpressionBinding], profile: MOSInputProfile = .coreStrictV1,
        scope: MOSScopeID? = nil, invocation: UInt64 = 1, instance: String = "M1",
        scale: Double = 1, fingers: Bool = false) throws -> MOSResolutionRequest {
        try MOSResolutionRequest(instance: instance, scope: scope ?? root, scopeInstantiation: invocation,
            modelReference: model, profile: profile, bindings: values, geometryScale: scale,
            seed: 42, globalWidthPerFinger: fingers, limits: limits)
    }
}
