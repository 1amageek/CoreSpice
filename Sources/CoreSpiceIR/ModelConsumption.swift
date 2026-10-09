/// Source model consumption, independent of the device's physical binding map.
public enum ModelConsumption: Sendable {
    /// Caller did not record whether source models were consumed.
    case unrecorded
    /// Lowering verified this instance did not consume a source model.
    case modelFree
    /// The selected source model used to form this instance's physical parameters.
    case selected(ResolvedDeviceModel)
}
