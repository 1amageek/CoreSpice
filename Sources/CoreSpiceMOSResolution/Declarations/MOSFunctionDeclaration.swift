import CoreSpiceMOSContracts

public struct MOSFunctionDeclaration: Sendable, Hashable {
    public let id: MOSFunctionID
    public let symbol: MOSSymbolID
    public let scope: MOSScopeID
    public let parameters: [MOSSymbolID]
    public let program: MOSProgramID
    public let source: MOSSourceOccurrence?
    package init(id: MOSFunctionID, symbol: MOSSymbolID, scope: MOSScopeID, parameters: [MOSSymbolID],
                 program: MOSProgramID, source: MOSSourceOccurrence?) {
        self.id = id; self.symbol = symbol; self.scope = scope; self.parameters = parameters
        self.program = program; self.source = source
    }
}
