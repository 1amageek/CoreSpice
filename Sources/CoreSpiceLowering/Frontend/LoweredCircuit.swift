import CoreSpiceIR
import CoreSpiceMOSResolution

/// Resolution result retaining exact declaration and invocation inspection capability.
public struct LoweredCircuit: Sendable {
    public let circuit: CircuitIR
    public let compiled: CompiledNetlist
    public var snapshot: MOSDeclarationSnapshot { compiled.snapshot }
    public let graph: MOSInvocationGraph
    public let evaluationProvenance: NetlistEvaluationProvenance
}
