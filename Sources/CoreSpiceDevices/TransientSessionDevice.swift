/// A device whose accepted charge history is owned by one transient run.
public protocol TransientSessionDevice: TransientStateCommittingDevice {
    /// Rejects concurrent admission before mutating history.
    func beginTransientSession(initialState: SolutionState) throws
    /// Begins from an explicitly selected operating-point or initial-condition phase.
    func beginTransientSession(initialState: SolutionState, initialization: TransientInitialization) throws
    /// Releases an admitted session on every run exit.
    func endTransientSession()
}

extension TransientSessionDevice {
    public func beginTransientSession(initialState: SolutionState, initialization: TransientInitialization) throws {
        try beginTransientSession(initialState: initialState)
    }
}
