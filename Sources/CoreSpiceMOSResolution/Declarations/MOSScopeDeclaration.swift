import CoreSpiceMOSContracts

public struct MOSScopeDeclaration: Sendable, Hashable {
    public let id: MOSScopeID
    public let parent: MOSScopeID?
    public let source: MOSSourceOccurrence?
    public let parameterBindings: [MOSBindingID]
    public let functions: [MOSFunctionID]
    package init(id: MOSScopeID, parent: MOSScopeID?, source: MOSSourceOccurrence?,
                 parameterBindings: [MOSBindingID], functions: [MOSFunctionID]) {
        self.id = id; self.parent = parent; self.source = source
        self.parameterBindings = parameterBindings; self.functions = functions
    }
}
