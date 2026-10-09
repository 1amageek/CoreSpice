import CoreSpiceMOSContracts

public struct MOSBindingDeclaration: Sendable, Hashable {
    public let id: MOSBindingID
    public let symbol: MOSSymbolID
    public let scope: MOSScopeID
    public let program: MOSProgramID
    public let source: MOSSourceOccurrence?
    package init(id: MOSBindingID, symbol: MOSSymbolID, scope: MOSScopeID, program: MOSProgramID, source: MOSSourceOccurrence?) {
        self.id = id; self.symbol = symbol; self.scope = scope; self.program = program; self.source = source
    }
}
