import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceMOSContracts
import CoreSpiceLowering

/// Tests make every frontend policy explicit while keeping topology fixtures compact.
struct FrontendTestLowering {
    struct Configuration {
        var maxExpansionDepth = 64
        var expandModels = true
        var parameterOverrides: [String: Double] = [:]
        var geometryScale: Double? = nil
        static let `default` = Configuration()
    }
    var configuration: Configuration = .default
    static func limits(maxDepth: Int = 64, maximumRetainedBytes: UInt64 = 32 * 1024 * 1024) throws -> MOSResolutionLimits {
        try MOSResolutionLimits(maximumRetainedBytes: maximumRetainedBytes, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: maxDepth, maximumSymbols: 8192, maximumScopes: 1024,
            maximumInvocations: 4096, maximumInvocationBindings: 8192, maximumDeclarations: 1024,
            maximumPrograms: 16384, maximumBindings: 8192, maximumFunctions: 1024,
            maximumFunctionDepth: 64, maximumExpressionNodes: 16384, maximumExpressionDepth: 128,
            maximumCandidates: 1024, maximumCacheEntries: 16384, maximumEvaluationSteps: 4_000_000)
    }
    func lower(_ parsed: ParsedNetlist) throws -> CircuitIR {
        let limits = try Self.limits(maxDepth: configuration.maxExpansionDepth)
        let compiled = try NetlistLowering.compile(parsed, additionalOverrideNames: Array(configuration.parameterOverrides.keys), limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1,
            limits: limits, seed: 42, parameterOverrides: configuration.parameterOverrides)
        try session.lower(geometryScale: configuration.geometryScale, expandModels: configuration.expandModels, diodeProfile: .coreDiodeV1)
        return try session.finish().circuit
    }
}
