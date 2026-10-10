import CoreSpiceMOSContracts

/// Prepares one exact resolved device for explicit execution conditions.
public protocol MOSDevicePreparing: Sendable {
    func prepare(_ input: borrowing MOSPreparationInput, limits: MOSPreparationLimits,
                 control: any MOSPreparationControlling)
        throws(MOSPreparationFailure) -> NativePreparedMOSDevice
}
