import CoreSpiceMOSContracts

package enum MOSEvaluationFrame {
    case expression(MOSExpression, MOSEvaluationContext, depth: Int)
    case unary(MOSUnaryOperator)
    case binaryLeft(MOSBinaryOperator, MOSExpression, MOSEvaluationContext, depth: Int)
    case binaryRight(MOSBinaryOperator, Double)
    case conditional(MOSExpression, MOSExpression, MOSEvaluationContext, depth: Int)
    case arguments(MOSSymbolID, [MOSExpression], next: Int, base: Int, MOSEvaluationContext, depth: Int)
    case bindingEnd(MOSInvocationBindingKey)
    case functionEnd(MOSFunctionID, formalsBase: Int)
}
