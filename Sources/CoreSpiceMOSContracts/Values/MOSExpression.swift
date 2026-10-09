/// A compiled lexical AST; references retain interned symbol identities.
public indirect enum MOSExpression: Sendable, Hashable {
    case literal(Double)
    case reference(MOSSymbolID)
    case unary(MOSUnaryOperator, MOSExpression)
    case binary(MOSBinaryOperator, MOSExpression, MOSExpression)
    case function(MOSSymbolID, arguments: [MOSExpression])
    case conditional(condition: MOSExpression, then: MOSExpression, else: MOSExpression)
}
