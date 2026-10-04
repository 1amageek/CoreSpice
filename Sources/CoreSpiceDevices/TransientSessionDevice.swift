/// A device whose accepted charge history is owned by one transient run.
public protocol TransientSessionDevice: TransientStateCommittingDevice {
    /// Rejects concurrent admission before mutating history.
    func beginTransientSession(initialState: SolutionState) throws
    /// Releases an admitted session on every run exit.
    func endTransientSession()
}
