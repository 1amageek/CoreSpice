import CoreSpiceMOSContracts

public struct MOSModelDeclaration: Sendable, Hashable {
    public let id: MOSDeclarationID
    public let name: MOSSymbolID
    public let originalName: String
    public let family: MOSSymbolID?
    public let scope: MOSScopeID
    public let polarity: MOSPolarity
    public let level: Int?
    public let version: String?
    public let coefficients: [MOSExpressionBinding]
    public let source: MOSSourceOccurrence
    package init(id: MOSDeclarationID, name: MOSSymbolID, originalName: String, family: MOSSymbolID?,
                 scope: MOSScopeID, polarity: MOSPolarity, level: Int?, version: String?,
                 coefficients: [MOSExpressionBinding], source: MOSSourceOccurrence) {
        self.id = id; self.name = name; self.originalName = originalName; self.family = family
        self.scope = scope; self.polarity = polarity; self.level = level; self.version = version
        self.coefficients = coefficients; self.source = source
    }
}
