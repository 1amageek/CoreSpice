import CoreSpiceDevices

extension DeviceRegistry {

    /// Register all optoelectronic device descriptors.
    ///
    /// Call this after `DeviceRegistry.standard()` to add support for
    /// photodiodes, LEDs, laser diodes, EO modulators, waveguides,
    /// and optical splitters.
    public mutating func registerOptoelectronicDevices() {
        register(PhotodiodeDescriptor())
        register(LEDDescriptor())
        register(LaserDiodeDescriptor())
        register(EOModulatorDescriptor())
        register(OpticalWaveguideDescriptor())
        register(OpticalSplitterDescriptor())
    }

    /// A registry pre-populated with all built-in device types
    /// plus all optoelectronic device types.
    public static func withOptoelectronics() -> DeviceRegistry {
        var registry = standard()
        registry.registerOptoelectronicDevices()
        return registry
    }
}
