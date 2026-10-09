public struct MOSExpressionBinding: Sendable, Hashable {
    public let symbol: MOSSymbolID
    public let program: MOSProgramID
    public init(symbol: MOSSymbolID, program: MOSProgramID) { self.symbol = symbol; self.program = program }
}
