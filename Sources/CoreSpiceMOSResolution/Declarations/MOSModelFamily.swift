import CoreSpiceMOSContracts

public struct MOSModelFamily: Sendable, Hashable {
    public let scope: MOSScopeID
    public let name: MOSSymbolID
    /// Range in snapshot.familyDeclarationIDs, not in the ordered declaration table.
    public let range: Range<Int>
    package init(scope: MOSScopeID, name: MOSSymbolID, range: Range<Int>) {
        self.scope = scope; self.name = name; self.range = range
    }
}
