/// Checked resolution and explicit conditions; no coefficient projection or numerical setup.
public struct MOSPreparationInput: Sendable, Hashable {
    public let resolved: ResolvedMOSInstance
    public let conditions: MOSPreparationConditions
    public init(resolved: ResolvedMOSInstance, conditions: MOSPreparationConditions) {
        self.resolved = resolved; self.conditions = conditions
    }
}
