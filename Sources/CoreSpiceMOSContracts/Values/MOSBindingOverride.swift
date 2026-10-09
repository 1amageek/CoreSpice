public struct MOSBindingOverride: Sendable, Hashable {
    public let binding: MOSBindingID
    public let program: MOSProgramID
    /// Only the target symbol self-reference uses this caller scope; other references use the final target scope.
    public let evaluationScope: MOSScopeID
    public init(binding: MOSBindingID, program: MOSProgramID, evaluationScope: MOSScopeID) {
        self.binding = binding; self.program = program; self.evaluationScope = evaluationScope
    }
}
