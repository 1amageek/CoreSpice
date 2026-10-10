import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceParsedIR

/// Resolves compiled assignments through the caller's exclusive scalar session.
public protocol SPICENodeVoltageResolving: Sendable {
    func resolve(_ kind: SPICENodeVoltageAssignmentKind, compiled: CompiledNetlist,
                 session: inout NetlistLoweringSession, circuit: CircuitIR)
    throws(SPICENodeVoltageResolutionError) -> [Node: Double]
    func resolveBounded(_ kind: SPICENodeVoltageAssignmentKind, compiled: CompiledNetlist,
                        session: inout NetlistLoweringSession, circuit: CircuitIR,
                        resources: any SPICESourceResourceAccounting)
    throws(SPICENodeVoltageResolutionError) -> SPICEOwnedNodeVoltages
}
