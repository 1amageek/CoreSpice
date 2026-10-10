import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

struct MOSSelectionFixture: ~Copyable {
    let limits: MOSResolutionLimits
    var builder: MOSDeclarationSnapshotBuilder
    let root: MOSScopeID
    let model: MOSSymbolID
    let l: MOSSymbolID
    let w: MOSSymbolID
    let nf: MOSSymbolID
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
        let l = try builder.intern("l"), w = try builder.intern("w"), nf = try builder.intern("nf")
        self.limits = limits
        self.builder = consume builder
        self.root = root; self.model = model
        self.l = l; self.w = w; self.nf = nf
    }
    mutating func binding(_ name: String, _ value: Double) throws -> MOSExpressionBinding {
        guard !didFinish else { throw MOSResolutionFailure.invalidRequest }
        let symbol = try builder.intern(name)
        let program = try builder.addProgram(.literal(value))
        return MOSExpressionBinding(symbol: symbol, program: program)
    }
    mutating func bin(_ name: String, scope: MOSScopeID? = nil,
        bounds: [Double?] = [1e-6, 2e-6, 1e-6, 2e-6], extras: [MOSExpressionBinding] = [],
        level: Int? = 54, version: String? = "4.8.3") throws -> MOSDeclarationID {
        guard !didFinish else { throw MOSResolutionFailure.invalidRequest }
        var coefficients: [MOSExpressionBinding] = []
        for (name, value) in zip(["lmin", "lmax", "wmin", "wmax"], bounds) {
            if let value { coefficients.append(try binding(name, value)) }
        }
        coefficients.append(contentsOf: extras)
        return try builder.addModel(name: name, scope: scope ?? root, polarity: .nmos,
            level: level, version: version, coefficients: coefficients, source: Self.source(name))
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
