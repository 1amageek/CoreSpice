import CoreSpiceIO

/// Explicit finite evaluation policy shared only by these IO regression fixtures.
internal enum IOTestFrontend {
    static var limits: MOSResolutionLimits {
        get throws {
            try MOSResolutionLimits(maximumRetainedBytes: 16 * 1024 * 1024, maximumDiagnosticBytes: 8192,
                maximumScopeDepth: 128, maximumSymbols: 32768, maximumScopes: 1024,
                maximumInvocations: 4096, maximumInvocationBindings: 32768, maximumDeclarations: 32768,
                maximumPrograms: 65536, maximumBindings: 65536, maximumFunctions: 1024, maximumFunctionDepth: 128,
                maximumExpressionNodes: 262144, maximumExpressionDepth: 256, maximumCandidates: 32768,
                maximumCacheEntries: 65536, maximumEvaluationSteps: 2_000_000)
        }
    }
    static func parseAndLower(_ source: String) async throws -> CircuitIR {
        try await SPICEIO.parseAndLower(source, profile: .coreStrictV1, seed: 42, limits: limits).circuit
    }
    static func lower(_ source: ParsedNetlist) throws -> CircuitIR {
        try SPICEIO.lower(source, profile: .coreStrictV1, seed: 42, limits: limits).circuit
    }
    static func options(_ source: ParsedNetlist) throws -> SPICEAnalysisOptions {
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 42)
        return try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
    }
}
