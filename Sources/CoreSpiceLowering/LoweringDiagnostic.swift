import CoreSpiceParsedIR

/// Machine-readable lowering diagnostic for Agent and CLI consumers.
public struct LoweringDiagnostic: Codable, Hashable, Sendable {

    public let severity: String
    public let code: String
    public let message: String
    public let location: SourceLocation?
    public let subject: String?
    public let details: [String: String]
    public let suggestedActions: [String]

    public init(
        severity: String,
        code: String,
        message: String,
        location: SourceLocation? = nil,
        subject: String? = nil,
        details: [String: String] = [:],
        suggestedActions: [String] = []
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.location = location
        self.subject = subject
        self.details = details
        self.suggestedActions = suggestedActions
    }
}

public extension LoweringError {

    /// Returns a structured diagnostic that preserves the typed failure context.
    var diagnostic: LoweringDiagnostic {
        switch self {
        case .undefinedParameter(let name, let location):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.undefined_parameter",
                message: description,
                location: location,
                subject: name,
                details: ["parameter": name],
                suggestedActions: [
                    "define-parameter",
                    "correct-parameter-reference"
                ]
            )

        case .undefinedModel(let name, let location):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.undefined_model",
                message: description,
                location: location,
                subject: name,
                details: ["model": name],
                suggestedActions: [
                    "define-model",
                    "correct-model-reference"
                ]
            )

        case .undefinedSubcircuit(let name, let location):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.undefined_subcircuit",
                message: description,
                location: location,
                subject: name,
                details: ["subcircuit": name],
                suggestedActions: [
                    "define-subcircuit",
                    "correct-subcircuit-reference"
                ]
            )

        case .circularParameterDependency(let parameter):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.circular_parameter_dependency",
                message: description,
                subject: parameter,
                details: ["parameter": parameter],
                suggestedActions: [
                    "break-parameter-cycle",
                    "inline-or-rename-dependent-parameter"
                ]
            )

        case .expressionEvaluationFailed(let expression, let reason):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.expression_evaluation_failed",
                message: description,
                subject: expression,
                details: [
                    "expression": expression,
                    "reason": reason
                ],
                suggestedActions: [
                    "inspect-expression-dependencies",
                    "define-missing-parameters"
                ]
            )

        case .invalidComponent(let name, let reason):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.invalid_component",
                message: description,
                subject: name.isEmpty ? nil : name,
                details: invalidComponentDetails(name: name, reason: reason),
                suggestedActions: invalidComponentSuggestedActions(reason: reason)
            )

        case .portCountMismatch(let subcircuit, let expected, let got):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.subcircuit_port_count_mismatch",
                message: description,
                subject: subcircuit,
                details: [
                    "subcircuit": subcircuit,
                    "expected": String(expected),
                    "got": String(got)
                ],
                suggestedActions: [
                    "align-instance-node-count-with-subcircuit-ports",
                    "inspect-subcircuit-port-list"
                ]
            )

        case .maxExpansionDepthExceeded(let depth):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.max_expansion_depth_exceeded",
                message: description,
                details: ["depth": String(depth)],
                suggestedActions: [
                    "check-recursive-subcircuit-instantiation",
                    "increase-max-expansion-depth-if-intentional"
                ]
            )

        case .invalidNode(let name):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.invalid_node",
                message: description,
                subject: name,
                details: ["node": name],
                suggestedActions: [
                    "correct-node-name",
                    "inspect-component-connectivity"
                ]
            )

        case .unsupportedFeature(let feature):
            return LoweringDiagnostic(
                severity: "error",
                code: "lowering.unsupported_feature",
                message: description,
                subject: feature,
                details: ["feature": feature],
                suggestedActions: [
                    "select-supported-native-feature",
                    "route-deck-to-external-compatible-engine"
                ]
            )
        }
    }

    private func invalidComponentDetails(name: String, reason: String) -> [String: String] {
        var details = ["reason": reason]
        if !name.isEmpty {
            details["component"] = name
        }
        return details
    }

    private func invalidComponentSuggestedActions(reason: String) -> [String] {
        if reason.contains(".model reference") {
            return ["add-model-reference", "define-compatible-model"]
        }
        if reason.contains("not executable") || reason.contains("not implemented") {
            return ["select-supported-model-or-device", "route-deck-to-external-compatible-engine"]
        }
        if reason.contains("requires") {
            return ["fix-component-card-shape", "inspect-required-terminals-or-parameters"]
        }
        if reason.contains("conflicts with a public subcircuit parameter") {
            return ["rename-local-subcircuit-parameter", "remove-shadowing-parameter"]
        }
        if reason.contains("non-negative") {
            return ["correct-physical-parameter-sign", "inspect-model-parameter-units"]
        }
        return ["inspect-component-definition", "correct-component-parameters"]
    }
}
