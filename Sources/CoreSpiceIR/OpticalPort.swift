/// The direction of an optical port.
public enum OpticalPortDirection: Sendable, Hashable {
    case input
    case output
    case bidirectional
}

/// A named optical port on a device.
///
/// Optical ports define the optical connection interface of a device,
/// similar to electrical `Port` but for the optical domain.
public struct OpticalPort: Hashable, Sendable {

    public let name: String
    public let index: Int
    public let direction: OpticalPortDirection

    public init(name: String, index: Int, direction: OpticalPortDirection) {
        self.name = name
        self.index = index
        self.direction = direction
    }
}
