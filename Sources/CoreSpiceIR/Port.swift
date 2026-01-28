/// A named port on a device or subcircuit.
///
/// Ports define the external connection interface of a device,
/// mapping a human-readable name to a positional index.
public struct Port: Hashable, Sendable {

    public let name: String
    public let index: Int

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }
}
