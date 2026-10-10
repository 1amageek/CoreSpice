public enum MOSResolutionWork: String, Sendable, Hashable {
    case symbols, scopes, invocations, invocationBindings, declarations, programs, bindings, functions
    case expressionNodes, expressionDepth, functionDepth, candidates, cacheEntries, evaluationSteps, identifierBytes, indexEntries, retainedBytes, diagnosticBytes, scopeDepth
}
