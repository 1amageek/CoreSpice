import CoreSpiceParsedIR

/// Errors that can occur during netlist lowering.
public enum LoweringError: Error, Sendable {

    /// A referenced parameter was not found.
    case undefinedParameter(name: String, location: SourceLocation?)

    /// A referenced model was not found.
    case undefinedModel(name: String, location: SourceLocation?)

    /// A referenced subcircuit was not found.
    case undefinedSubcircuit(name: String, location: SourceLocation?)

    /// A circular parameter dependency was detected.
    case circularParameterDependency(parameter: String)

    /// Expression evaluation failed.
    case expressionEvaluationFailed(expression: String, reason: String)

    /// Invalid component configuration.
    case invalidComponent(name: String, reason: String)

    /// Subcircuit port count mismatch.
    case portCountMismatch(subcircuit: String, expected: Int, got: Int)

    /// Maximum expansion depth exceeded.
    case maxExpansionDepthExceeded(depth: Int)

    /// Invalid node reference.
    case invalidNode(name: String)

    /// Unsupported feature.
    case unsupportedFeature(feature: String)
}

extension LoweringError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .undefinedParameter(let name, let loc):
            var msg = "Undefined parameter: \(name)"
            if let l = loc { msg += " at \(l)" }
            return msg

        case .undefinedModel(let name, let loc):
            var msg = "Undefined model: \(name)"
            if let l = loc { msg += " at \(l)" }
            return msg

        case .undefinedSubcircuit(let name, let loc):
            var msg = "Undefined subcircuit: \(name)"
            if let l = loc { msg += " at \(l)" }
            return msg

        case .circularParameterDependency(let parameter):
            return "Circular parameter dependency detected for: \(parameter)"

        case .expressionEvaluationFailed(let expr, let reason):
            return "Failed to evaluate expression '\(expr)': \(reason)"

        case .invalidComponent(let name, let reason):
            return "Invalid component '\(name)': \(reason)"

        case .portCountMismatch(let subcircuit, let expected, let got):
            return "Port count mismatch for subcircuit '\(subcircuit)': expected \(expected), got \(got)"

        case .maxExpansionDepthExceeded(let depth):
            return "Maximum subcircuit expansion depth (\(depth)) exceeded"

        case .invalidNode(let name):
            return "Invalid node reference: \(name)"

        case .unsupportedFeature(let feature):
            return "Unsupported feature: \(feature)"
        }
    }
}
