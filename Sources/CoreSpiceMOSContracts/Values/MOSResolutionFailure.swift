public enum MOSResolutionFailure: Error, Sendable, Equatable {
    case invalidLimits
    case limitExceeded(MOSResolutionWork)
    case cancelled
    case arithmeticOverflow
    case invalidIdentifier(String)
    case invalidReference(table: String, index: UInt32)
    case invalidScope
    case invalidInvocation(UInt64)
    case duplicateInvocation(UInt64)
    case conditionMismatch
    case duplicateParameter(MOSSymbolID)
    case undefinedParameter(MOSSymbolID)
    case circularBinding(MOSBindingID)
    case circularInvocationBinding(invocation: UInt64, symbol: MOSSymbolID)
    case recursiveFunction(MOSFunctionID)
    case invalidFunctionArity(MOSSymbolID)
    case unsupportedFunction(MOSSymbolID)
    case invalidFunctionDomain(MOSSymbolID)
    case invalidArithmetic
    case nonFiniteExpression
    case invalidGeometry(String)
    case nonFiniteValue(MOSSymbolID)
    case invalidRequest
    case missingModel(MOSSymbolID)
    case duplicateModel(MOSSymbolID)
    case ambiguousModel(MOSSymbolID)
    case noMatchingBin(MOSSymbolID)
    case invalidBin(MOSDeclarationID)
    case schema(MOSSchemaFailure)
    case invalidResolvedInstance
    case poisonedSession
}
