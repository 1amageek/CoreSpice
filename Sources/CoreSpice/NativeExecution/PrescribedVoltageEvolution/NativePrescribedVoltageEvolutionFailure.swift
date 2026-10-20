/// Evolution admission failures; original numerical/control/domain causes remain distinct.
package enum NativePrescribedVoltageEvolutionFailure: Error, Sendable, Equatable {
    case invalidInput, invalidBinding, wrongOwner, capacityExceeded
}
