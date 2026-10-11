/// Composition failures remain distinct from original numerical kernel failures.
public enum BSIM45DeviceError: Error, Sendable, Equatable {
    case invalidAuxiliaryTopology(String)
    case transientSessionAlreadyActive(String)
    case transientSessionRequired(String)
    case terminalInitialConditionsConflict(String)
}
