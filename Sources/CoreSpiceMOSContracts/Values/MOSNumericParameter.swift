public struct MOSNumericParameter: Sendable, Hashable {
    public let symbol: MOSSymbolID
    public let value: Double
    public init(symbol: MOSSymbolID, value: Double) { self.symbol = symbol; self.value = value }
}
