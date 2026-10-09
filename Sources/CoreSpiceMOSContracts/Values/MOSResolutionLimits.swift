/// Explicit caller budgets; there is no implicit unlimited/default profile.
public struct MOSResolutionLimits: Sendable, Hashable {
    public let maximumRetainedBytes: UInt64
    public let maximumDiagnosticBytes: UInt64
    public let maximumScopeDepth: Int
    public let maximumSymbols: Int
    public let maximumScopes: Int
    public let maximumDeclarations: Int
    public let maximumPrograms: Int
    public let maximumBindings: Int
    public let maximumFunctions: Int
    public let maximumExpressionNodes: Int
    public let maximumExpressionDepth: Int
    public let maximumCandidates: Int
    public let maximumCacheEntries: Int
    public let maximumEvaluationSteps: UInt64
    public init(maximumRetainedBytes: UInt64, maximumDiagnosticBytes: UInt64, maximumScopeDepth: Int, maximumSymbols: Int, maximumScopes: Int, maximumDeclarations: Int,
                maximumPrograms: Int, maximumBindings: Int, maximumFunctions: Int,
                maximumExpressionNodes: Int, maximumExpressionDepth: Int,
                maximumCandidates: Int, maximumCacheEntries: Int, maximumEvaluationSteps: UInt64) throws(MOSResolutionFailure) {
        guard maximumRetainedBytes > 0, maximumDiagnosticBytes > 0, maximumScopeDepth > 0, maximumSymbols > 0, maximumScopes > 0, maximumDeclarations > 0,
              maximumPrograms > 0, maximumBindings > 0, maximumFunctions > 0,
              maximumExpressionNodes > 0, maximumExpressionDepth > 0,
              maximumCandidates > 0, maximumCacheEntries > 0, maximumEvaluationSteps > 0 else {
            throw .invalidLimits
        }
        self.maximumRetainedBytes = maximumRetainedBytes; self.maximumDiagnosticBytes = maximumDiagnosticBytes
        self.maximumScopeDepth = maximumScopeDepth
        self.maximumSymbols = maximumSymbols; self.maximumScopes = maximumScopes
        self.maximumDeclarations = maximumDeclarations; self.maximumPrograms = maximumPrograms
        self.maximumBindings = maximumBindings; self.maximumFunctions = maximumFunctions
        self.maximumExpressionNodes = maximumExpressionNodes; self.maximumExpressionDepth = maximumExpressionDepth
        self.maximumCandidates = maximumCandidates; self.maximumCacheEntries = maximumCacheEntries
        self.maximumEvaluationSteps = maximumEvaluationSteps
    }
}
