import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceParsedIR

/// Resolves parsed voltage assignments against actual circuit node semantics.
public protocol SPICENodeVoltageResolving: Sendable {
    func resolve(assignments: [String: ParsedParameterValue], circuit: CircuitIR,
                 evaluator: ExpressionEvaluator) throws(SPICENodeVoltageResolutionError) -> [Node: Double]
    func resolveBounded(assignments: [String: ParsedParameterValue], circuit: CircuitIR,
                        resources: any SPICESourceResourceAccounting)
    throws(SPICENodeVoltageResolutionError) -> SPICEOwnedNodeVoltages
}
