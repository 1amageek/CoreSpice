import CoreSpiceIR
import Foundation

/// Allocation-free scalar automatic differentiation for canonical behavioral expressions.
struct BehavioralExpressionEvaluator: Sendable {
    struct Evaluation: Sendable {
        let value: Double
        let derivative: Double
    }

    let dependencyIndices: [Int]

    private let expression: BehavioralExpression
    private let nodeIndices: [Node: Int]
    private let branchReferenceIndices: [Int]

    init(
        expression: BehavioralExpression,
        instance: Instance,
        context: BindingContext
    ) throws {
        var dependencies: Set<Int> = []
        var nodeIndices: [Node: Int] = [:]
        var branchReferenceIndices: [Int] = []
        branchReferenceIndices.reserveCapacity(instance.referencedBranches.count)

        for branch in instance.referencedBranches {
            guard let index = context.branchIndex(branch) else {
                throw DeviceBindingError.missingBranchVariable(
                    device: instance.name,
                    ownedIndex: branchReferenceIndices.count
                )
            }
            branchReferenceIndices.append(index)
        }

        try Self.collectDependencies(
            expression,
            instanceName: instance.name,
            context: context,
            nodeIndices: &nodeIndices,
            branchReferenceIndices: branchReferenceIndices,
            dependencies: &dependencies
        )

        self.expression = expression
        self.nodeIndices = nodeIndices
        self.branchReferenceIndices = branchReferenceIndices
        self.dependencyIndices = dependencies.sorted()
    }

    func evaluate(
        state: SolutionState,
        time: Double,
        differentiating variableIndex: Int? = nil
    ) -> Evaluation {
        evaluate(
            expression,
            state: state,
            time: time,
            variableIndex: variableIndex
        )
    }

    private static func collectDependencies(
        _ expression: BehavioralExpression,
        instanceName: String,
        context: BindingContext,
        nodeIndices: inout [Node: Int],
        branchReferenceIndices: [Int],
        dependencies: inout Set<Int>
    ) throws {
        switch expression {
        case .constant:
            return
        case .variable(let variable):
            switch variable {
            case .nodeVoltage(let positive, let negative):
                if positive != .ground {
                    guard let index = context.nodeIndex(positive) else {
                        throw DeviceBindingError.invalidParameterValue(
                            device: instanceName,
                            parameter: "expression",
                            message: "Referenced positive node is absent from the compiled topology"
                        )
                    }
                    nodeIndices[positive] = index
                    dependencies.insert(index)
                }
                if negative != .ground {
                    guard let index = context.nodeIndex(negative) else {
                        throw DeviceBindingError.invalidParameterValue(
                            device: instanceName,
                            parameter: "expression",
                            message: "Referenced negative node is absent from the compiled topology"
                        )
                    }
                    nodeIndices[negative] = index
                    dependencies.insert(index)
                }
            case .branchCurrentReference(let referenceIndex):
                guard branchReferenceIndices.indices.contains(referenceIndex) else {
                    throw DeviceBindingError.invalidParameterValue(
                        device: instanceName,
                        parameter: "expression",
                        message: "Branch-current reference index \(referenceIndex) is unresolved"
                    )
                }
                dependencies.insert(branchReferenceIndices[referenceIndex])
            case .time:
                return
            }
        case .unary(_, let operand):
            try collectDependencies(
                operand,
                instanceName: instanceName,
                context: context,
                nodeIndices: &nodeIndices,
                branchReferenceIndices: branchReferenceIndices,
                dependencies: &dependencies
            )
        case .binary(_, let lhs, let rhs):
            try collectDependencies(
                lhs,
                instanceName: instanceName,
                context: context,
                nodeIndices: &nodeIndices,
                branchReferenceIndices: branchReferenceIndices,
                dependencies: &dependencies
            )
            try collectDependencies(
                rhs,
                instanceName: instanceName,
                context: context,
                nodeIndices: &nodeIndices,
                branchReferenceIndices: branchReferenceIndices,
                dependencies: &dependencies
            )
        case .function(_, let arguments):
            for argument in arguments {
                try collectDependencies(
                    argument,
                    instanceName: instanceName,
                    context: context,
                    nodeIndices: &nodeIndices,
                    branchReferenceIndices: branchReferenceIndices,
                    dependencies: &dependencies
                )
            }
        case .conditional(let condition, let then, let `else`):
            try collectDependencies(
                condition,
                instanceName: instanceName,
                context: context,
                nodeIndices: &nodeIndices,
                branchReferenceIndices: branchReferenceIndices,
                dependencies: &dependencies
            )
            try collectDependencies(
                then,
                instanceName: instanceName,
                context: context,
                nodeIndices: &nodeIndices,
                branchReferenceIndices: branchReferenceIndices,
                dependencies: &dependencies
            )
            try collectDependencies(
                `else`,
                instanceName: instanceName,
                context: context,
                nodeIndices: &nodeIndices,
                branchReferenceIndices: branchReferenceIndices,
                dependencies: &dependencies
            )
        }
    }

    private func evaluate(
        _ expression: BehavioralExpression,
        state: SolutionState,
        time: Double,
        variableIndex: Int?
    ) -> Evaluation {
        switch expression {
        case .constant(let value):
            return Evaluation(value: value, derivative: 0)
        case .variable(let variable):
            return evaluate(
                variable,
                state: state,
                time: time,
                variableIndex: variableIndex
            )
        case .unary(let operation, let operand):
            return evaluate(
                operation,
                operand: evaluate(
                    operand,
                    state: state,
                    time: time,
                    variableIndex: variableIndex
                )
            )
        case .binary(let operation, let lhs, let rhs):
            return evaluate(
                operation,
                lhs: evaluate(lhs, state: state, time: time, variableIndex: variableIndex),
                rhs: evaluate(rhs, state: state, time: time, variableIndex: variableIndex)
            )
        case .function(let function, let arguments):
            return evaluate(
                function,
                arguments: arguments,
                state: state,
                time: time,
                variableIndex: variableIndex
            )
        case .conditional(let condition, let then, let `else`):
            let conditionValue = evaluate(
                condition,
                state: state,
                time: time,
                variableIndex: variableIndex
            )
            return evaluate(
                conditionValue.value != 0 ? then : `else`,
                state: state,
                time: time,
                variableIndex: variableIndex
            )
        }
    }

    private func evaluate(
        _ variable: BehavioralVariable,
        state: SolutionState,
        time: Double,
        variableIndex: Int?
    ) -> Evaluation {
        switch variable {
        case .nodeVoltage(let positive, let negative):
            let positiveIndex = nodeIndices[positive]
            let negativeIndex = nodeIndices[negative]
            let value = (positiveIndex.map { state.value(at: $0) } ?? 0)
                - (negativeIndex.map { state.value(at: $0) } ?? 0)
            var derivative = 0.0
            if positiveIndex == variableIndex {
                derivative += 1
            }
            if negativeIndex == variableIndex {
                derivative -= 1
            }
            return Evaluation(value: value, derivative: derivative)
        case .branchCurrentReference(let referenceIndex):
            let index = branchReferenceIndices[referenceIndex]
            return Evaluation(
                value: state.value(at: index),
                derivative: index == variableIndex ? 1 : 0
            )
        case .time:
            return Evaluation(value: time, derivative: 0)
        }
    }

    private func evaluate(
        _ operation: BehavioralUnaryOperator,
        operand: Evaluation
    ) -> Evaluation {
        switch operation {
        case .negate:
            return Evaluation(value: -operand.value, derivative: -operand.derivative)
        case .logicalNot:
            return Evaluation(value: operand.value == 0 ? 1 : 0, derivative: 0)
        case .plus:
            return operand
        }
    }

    private func evaluate(
        _ operation: BehavioralBinaryOperator,
        lhs: Evaluation,
        rhs: Evaluation
    ) -> Evaluation {
        switch operation {
        case .add:
            return Evaluation(
                value: lhs.value + rhs.value,
                derivative: lhs.derivative + rhs.derivative
            )
        case .subtract:
            return Evaluation(
                value: lhs.value - rhs.value,
                derivative: lhs.derivative - rhs.derivative
            )
        case .multiply:
            return Evaluation(
                value: lhs.value * rhs.value,
                derivative: lhs.derivative * rhs.value + lhs.value * rhs.derivative
            )
        case .divide:
            return Evaluation(
                value: lhs.value / rhs.value,
                derivative: (
                    lhs.derivative * rhs.value - lhs.value * rhs.derivative
                ) / (rhs.value * rhs.value)
            )
        case .power:
            return ordinaryPower(base: lhs, exponent: rhs)
        case .modulo:
            let quotient = floor(lhs.value / rhs.value)
            return Evaluation(
                value: lhs.value.truncatingRemainder(dividingBy: rhs.value),
                derivative: lhs.derivative - quotient * rhs.derivative
            )
        case .equal:
            return boolean(lhs.value == rhs.value)
        case .notEqual:
            return boolean(lhs.value != rhs.value)
        case .lessThan:
            return boolean(lhs.value < rhs.value)
        case .lessOrEqual:
            return boolean(lhs.value <= rhs.value)
        case .greaterThan:
            return boolean(lhs.value > rhs.value)
        case .greaterOrEqual:
            return boolean(lhs.value >= rhs.value)
        case .logicalAnd:
            return boolean(lhs.value != 0 && rhs.value != 0)
        case .logicalOr:
            return boolean(lhs.value != 0 || rhs.value != 0)
        }
    }

    private func evaluate(
        _ function: BehavioralFunction,
        arguments: [BehavioralExpression],
        state: SolutionState,
        time: Double,
        variableIndex: Int?
    ) -> Evaluation {
        func argument(_ index: Int) -> Evaluation {
            evaluate(
                arguments[index],
                state: state,
                time: time,
                variableIndex: variableIndex
            )
        }

        let first = argument(0)
        switch function {
        case .sine:
            return chain(value: sin(first.value), slope: cos(first.value), argument: first)
        case .cosine:
            return chain(value: cos(first.value), slope: -sin(first.value), argument: first)
        case .tangent:
            let cosine = cos(first.value)
            return chain(
                value: tan(first.value),
                slope: 1 / (cosine * cosine),
                argument: first
            )
        case .arcSine:
            return chain(
                value: asin(first.value),
                slope: 1 / sqrt(1 - first.value * first.value),
                argument: first
            )
        case .arcCosine:
            return chain(
                value: acos(first.value),
                slope: -1 / sqrt(1 - first.value * first.value),
                argument: first
            )
        case .arcTangent:
            return chain(
                value: atan(first.value),
                slope: 1 / (1 + first.value * first.value),
                argument: first
            )
        case .arcTangent2:
            let second = argument(1)
            let denominator = first.value * first.value + second.value * second.value
            return Evaluation(
                value: atan2(first.value, second.value),
                derivative: (
                    second.value * first.derivative - first.value * second.derivative
                ) / denominator
            )
        case .hyperbolicSine:
            return chain(value: sinh(first.value), slope: cosh(first.value), argument: first)
        case .hyperbolicCosine:
            return chain(value: cosh(first.value), slope: sinh(first.value), argument: first)
        case .hyperbolicTangent:
            let value = tanh(first.value)
            return chain(value: value, slope: 1 - value * value, argument: first)
        case .exponential:
            let value = exp(first.value)
            return chain(value: value, slope: value, argument: first)
        case .naturalLogarithm:
            return chain(value: log(first.value), slope: 1 / first.value, argument: first)
        case .commonLogarithm:
            return chain(
                value: log10(first.value),
                slope: 1 / (first.value * log(10)),
                argument: first
            )
        case .squareRoot:
            let value = sqrt(first.value)
            return chain(value: value, slope: 0.5 / value, argument: first)
        case .absoluteValue:
            let slope = first.value > 0 ? 1.0 : (first.value < 0 ? -1.0 : 0.0)
            return chain(value: abs(first.value), slope: slope, argument: first)
        case .sign:
            return Evaluation(
                value: first.value > 0 ? 1 : (first.value < 0 ? -1 : 0),
                derivative: 0
            )
        case .floor:
            return Evaluation(value: floor(first.value), derivative: 0)
        case .ceiling:
            return Evaluation(value: ceil(first.value), derivative: 0)
        case .round:
            return Evaluation(value: round(first.value), derivative: 0)
        case .truncate:
            return Evaluation(value: first.value.rounded(.towardZero), derivative: 0)
        case .minimum:
            var selected = first
            for index in arguments.indices.dropFirst() {
                let candidate = argument(index)
                if candidate.value < selected.value {
                    selected = candidate
                }
            }
            return selected
        case .maximum:
            var selected = first
            for index in arguments.indices.dropFirst() {
                let candidate = argument(index)
                if candidate.value > selected.value {
                    selected = candidate
                }
            }
            return selected
        case .clamp:
            let lower = argument(1)
            let upper = argument(2)
            if first.value < lower.value {
                return lower
            }
            if first.value > upper.value {
                return upper
            }
            return first
        case .power:
            return ordinaryPower(base: first, exponent: argument(1))
        case .positivePower:
            return power(base: first, exponent: argument(1), signed: false)
        case .signedPower:
            return power(base: first, exponent: argument(1), signed: true)
        }
    }

    private func power(
        base: Evaluation,
        exponent: Evaluation,
        signed: Bool
    ) -> Evaluation {
        let magnitude = abs(base.value)
        let unsignedValue = pow(magnitude, exponent.value)
        let sign = signed && base.value < 0 ? -1.0 : 1.0
        let value = sign * unsignedValue
        let baseSlope: Double
        if magnitude == 0 {
            baseSlope = exponent.value == 1 ? 1 : 0
        } else if signed {
            baseSlope = exponent.value * pow(magnitude, exponent.value - 1)
        } else {
            let baseSign = base.value < 0 ? -1.0 : 1.0
            baseSlope = baseSign * exponent.value * pow(magnitude, exponent.value - 1)
        }
        let exponentSlope = magnitude > 0 ? value * log(magnitude) : 0
        return Evaluation(
            value: value,
            derivative: baseSlope * base.derivative + exponentSlope * exponent.derivative
        )
    }

    private func ordinaryPower(
        base: Evaluation,
        exponent: Evaluation
    ) -> Evaluation {
        let value = pow(base.value, exponent.value)
        let baseSlope = exponent.value * pow(base.value, exponent.value - 1)
        let baseContribution = base.derivative == 0
            ? 0
            : baseSlope * base.derivative
        let exponentContribution = exponent.derivative == 0
            ? 0
            : value * log(base.value) * exponent.derivative
        return Evaluation(
            value: value,
            derivative: baseContribution + exponentContribution
        )
    }

    private func chain(
        value: Double,
        slope: Double,
        argument: Evaluation
    ) -> Evaluation {
        Evaluation(value: value, derivative: slope * argument.derivative)
    }

    private func boolean(_ value: Bool) -> Evaluation {
        Evaluation(value: value ? 1 : 0, derivative: 0)
    }
}
