import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts

/// A checked caller temperature or one snapshot-owned scalar condition program.
public enum MOSConditionInput: Sendable {
    case temperature(TemperatureKelvin)
    case program(MOSProgramID, invocation: UInt64, lexicalScope: MOSScopeID, source: MOSSourceOccurrence? = nil)
}
