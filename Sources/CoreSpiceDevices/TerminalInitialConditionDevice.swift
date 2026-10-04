import CoreSpiceIR

/// Multi-terminal voltage conditions applied by UIC before transient admission.
public protocol TerminalInitialConditionDevice: BoundDevice {
    var initialNodeVoltages: [Node: Double] { get }
}
