/// Inspection never closes or consumes its prepared owner.
public enum NativeVoltageSourceInspectionFailure: Error, Sendable {
    case cancelled
    case capacityExceeded
    case invalidBinding(device: String?)
    case unsupportedProducer(device: String)
    case invalidSourceLaw(device: String, cause: any Error)
    case resource(any Error)
    case callback(any Error)
}
