import CoreSpice

/// A simulation backend that exposes the capability and identity of an
/// explicitly selected external simulator.
public protocol CoreSpiceExternalSimulatorBackend: CoreSpiceSimulationBackend {
    var capability: CoreSpiceExternalSimulatorCapability { get }
}
