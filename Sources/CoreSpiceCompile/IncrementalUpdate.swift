/// Describes an incremental parameter change to an already-compiled circuit.
///
/// When only a subset of device parameters change between analysis runs
/// (e.g. during a parameter sweep), an ``IncrementalUpdate`` allows the
/// simulator to re-stamp only the affected devices rather than
/// recompiling the entire circuit.
public struct IncrementalUpdate: Sendable {

    /// The set of device instance names whose stamps must be refreshed.
    public let modifiedDevices: Set<String>

    /// New parameter values keyed by instance name, then parameter name.
    public let parameterChanges: [String: [String: Double]]

    public init(
        modifiedDevices: Set<String>,
        parameterChanges: [String: [String: Double]]
    ) {
        self.modifiedDevices = modifiedDevices
        self.parameterChanges = parameterChanges
    }
}
