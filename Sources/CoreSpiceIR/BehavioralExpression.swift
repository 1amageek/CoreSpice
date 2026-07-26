/// A simulation-time expression used by behavioral devices.
///
/// The expression is independent of source syntax. Node identities are
/// canonical IR nodes, while branch-current references index the owning
/// instance's `referencedBranches` collection.
public indirect enum BehavioralExpression: Sendable {
    case constant(Double)
    case variable(BehavioralVariable)
    case unary(BehavioralUnaryOperator, BehavioralExpression)
    case binary(BehavioralBinaryOperator, BehavioralExpression, BehavioralExpression)
    case function(BehavioralFunction, [BehavioralExpression])
    case conditional(
        condition: BehavioralExpression,
        then: BehavioralExpression,
        else: BehavioralExpression
    )
}

public enum BehavioralVariable: Sendable {
    case nodeVoltage(positive: Node, negative: Node)
    case branchCurrentReference(Int)
    case time
}

public enum BehavioralUnaryOperator: Sendable {
    case negate
    case logicalNot
    case plus
}

public enum BehavioralBinaryOperator: Sendable {
    case add
    case subtract
    case multiply
    case divide
    case power
    case modulo
    case equal
    case notEqual
    case lessThan
    case lessOrEqual
    case greaterThan
    case greaterOrEqual
    case logicalAnd
    case logicalOr
}

public enum BehavioralFunction: Sendable {
    case sine
    case cosine
    case tangent
    case arcSine
    case arcCosine
    case arcTangent
    case arcTangent2
    case hyperbolicSine
    case hyperbolicCosine
    case hyperbolicTangent
    case exponential
    case naturalLogarithm
    case commonLogarithm
    case squareRoot
    case absoluteValue
    case sign
    case floor
    case ceiling
    case round
    case truncate
    case minimum
    case maximum
    case clamp
    case power
    case positivePower
    case signedPower
}
