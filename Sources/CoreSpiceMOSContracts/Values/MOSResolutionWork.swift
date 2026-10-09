public enum MOSResolutionWork: String, Sendable, Hashable {
    case symbols, scopes, declarations, programs, bindings, functions
    case expressionNodes, expressionDepth, candidates, cacheEntries, evaluationSteps, identifierBytes, indexEntries, retainedBytes, diagnosticBytes, scopeDepth
}
