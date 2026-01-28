import CoreSpiceIR

/// Describes a device type and how to create bound instances of it.
///
/// Each descriptor declares the device's port interface and
/// parameter schema, and provides a factory method that
/// produces a `BoundDevice` ready for stamping.
public protocol DeviceDescriptor: Sendable {
    /// Unique type name used to look up this descriptor (e.g. "resistor").
    var typeName: String { get }
    /// Ordered names of the device ports.
    var portNames: [String] { get }
    /// Parameters the device accepts, with optional defaults.
    var parameterDescriptors: [ParameterDescriptor] { get }
    /// Create a bound device from an instance and a binding context.
    func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice
}
