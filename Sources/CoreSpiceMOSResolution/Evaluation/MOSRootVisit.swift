import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts

/// Ordered public evaluation roots, including memo hits; interpreter operand order is versioned.
public enum MOSRootVisit: Sendable, Hashable {
    case condition(EvaluationCondition, program: MOSProgramID?)
    case binding(MOSSymbolID, invocation: UInt64)
    case program(MOSProgramID, invocation: UInt64, lexicalScope: MOSScopeID)
}
