/// Failed geometry, binding or proof admission; unresolved leaves are separate evidence.
package enum NativePrescribedVoltageInitialCoverFailure: Error, Sendable, Equatable {
    case invalidInput, invalidBinding, wrongOwner, capacityExceeded, insufficientWitness, cancelled
}
