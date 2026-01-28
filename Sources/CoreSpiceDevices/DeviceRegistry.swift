/// A registry that maps device type names to their descriptors.
///
/// The analysis engine uses the registry to look up the correct
/// descriptor for each `Instance` in the circuit IR and then
/// bind it into a `BoundDevice`.
public struct DeviceRegistry: Sendable {

    private var descriptors: [String: any DeviceDescriptor] = [:]

    public init() {}

    /// Register a device descriptor.
    public mutating func register(_ descriptor: any DeviceDescriptor) {
        descriptors[descriptor.typeName] = descriptor
    }

    /// Look up a descriptor by type name.
    public func descriptor(for typeName: String) -> (any DeviceDescriptor)? {
        descriptors[typeName]
    }

    /// A registry pre-populated with all built-in device types.
    public static func standard() -> DeviceRegistry {
        var registry = DeviceRegistry()
        registry.register(ResistorDescriptor())
        registry.register(CapacitorDescriptor())
        registry.register(InductorDescriptor())
        registry.register(VoltageSourceDescriptor())
        registry.register(CurrentSourceDescriptor())
        registry.register(VCVSDescriptor())
        registry.register(VCCSDescriptor())
        registry.register(CCVSDescriptor())
        registry.register(CCCSDescriptor())
        registry.register(NMOSL1Descriptor())
        registry.register(PMOSL1Descriptor())
        return registry
    }
}
