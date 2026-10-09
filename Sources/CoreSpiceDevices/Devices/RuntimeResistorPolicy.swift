import CoreSpiceIR

/// Immutable operational ceilings for runtime resistance; these do not change its physical law.
public struct RuntimeResistorPolicy: Sendable {
    public let maxASTNodes: Int
    public let maxASTDepth: Int
    public let maxDependencies: Int
    public let maxEvaluationWork: Int
    public let defaultNoisy: Bool

    public static let `default` = RuntimeResistorPolicy(validatedDefaults: ())

    private init(validatedDefaults: Void) {
        self.maxASTNodes = 4096
        self.maxASTDepth = 64
        self.maxDependencies = 256
        self.maxEvaluationWork = 1_052_672
        self.defaultNoisy = false
    }

    public init(maxASTNodes: Int = 4096, maxASTDepth: Int = 64,
                maxDependencies: Int = 256, maxEvaluationWork: Int = 1_052_672,
                defaultNoisy: Bool = false) throws {
        guard maxASTNodes > 0, maxASTDepth > 0, maxASTDepth <= 64,
              maxDependencies > 0, maxEvaluationWork > 0 else {
            throw RuntimeResistorPolicyError.invalidCeiling
        }
        let (passes, additionOverflow) = maxDependencies.addingReportingOverflow(1)
        let (_, productOverflow) = maxASTNodes.multipliedReportingOverflow(by: passes)
        guard !additionOverflow, !productOverflow else {
            throw RuntimeResistorPolicyError.workOverflow
        }
        self.maxASTNodes = maxASTNodes
        self.maxASTDepth = maxASTDepth
        self.maxDependencies = maxDependencies
        self.maxEvaluationWork = maxEvaluationWork
        self.defaultNoisy = defaultNoisy
    }

    func admit(_ expression: BehavioralExpression, device: String) throws -> Int {
        func invalid(_ message: String) -> DeviceBindingError {
            .invalidParameterValue(device: device, parameter: "runtimePolicy", message: message)
        }
        // Admit each child before extending the traversal stack. Its retained storage
        // and all later recursive evaluator work are bounded by the admitted tree.
        var stack: [(BehavioralExpression, Int)] = [(expression, 1)]
        var scheduled = 1
        while let (node, depth) = stack.popLast() {
            let children: [BehavioralExpression]
            switch node {
            case .constant(let value):
                guard value.isFinite else { throw invalid("Expression constant must be finite") }
                children = []
            case .variable:
                children = []
            case .unary(_, let operand):
                children = [operand]
            case .binary(_, let lhs, let rhs):
                children = [lhs, rhs]
            case .conditional(let condition, let then, let otherwise):
                children = [condition, then, otherwise]
            case .function(let function, let arguments):
                let validArity: Bool
                switch function {
                case .arcTangent2, .power, .positivePower, .signedPower:
                    validArity = arguments.count == 2
                case .clamp:
                    validArity = arguments.count == 3
                case .minimum, .maximum:
                    validArity = !arguments.isEmpty
                default:
                    validArity = arguments.count == 1
                }
                guard validArity else { throw invalid("Malformed behavioral function arity") }
                children = arguments
            }
            guard children.isEmpty || depth < maxASTDepth else {
                throw invalid("Expression exceeds admitted AST depth")
            }
            guard children.count <= maxASTNodes - scheduled else {
                throw invalid("Expression exceeds admitted AST node count")
            }
            scheduled += children.count
            for child in children { stack.append((child, depth + 1)) }
        }
        return scheduled
    }

    func admitWork(nodes: Int, dependencies: Int, device: String) throws {
        let (passes, additionOverflow) = dependencies.addingReportingOverflow(1)
        let (work, productOverflow) = nodes.multipliedReportingOverflow(by: passes)
        guard dependencies <= maxDependencies, !additionOverflow, !productOverflow,
              work <= maxEvaluationWork else {
            throw DeviceBindingError.invalidParameterValue(device: device, parameter: "runtimePolicy",
                message: "Expression exceeds admitted dependency or per-stamp work ceiling")
        }
    }
}
