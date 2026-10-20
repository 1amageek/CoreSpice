import CoreSpiceIR

public enum NativePrescribedVoltageFlowObservationFailure: Error, Sendable {
    case invalidInput
    case unknownNode(Node)
    case nonElectricalNode(Node)
    case capacityExceeded
    case cancelled
    case operation(cause: any Error)
}
