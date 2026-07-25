public protocol AcceptedStateCommittingDevice: BoundDevice {
    func commitAcceptedState(_ state: SolutionState)
}
