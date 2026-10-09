import CoreSpiceMOSContracts

/// One immutable storage identity, reusable across sessions without array hashing.
public final class MOSDeclarationSnapshot: Sendable {
    public let symbols: [String]
    public let scopes: [MOSScopeDeclaration]
    public let declarations: [MOSModelDeclaration]
    public let programs: [MOSExpressionProgram]
    public let bindings: [MOSBindingDeclaration]
    public let functions: [MOSFunctionDeclaration]
    public let exactDeclarationIDs: [MOSDeclarationID]
    public let familyDeclarationIDs: [MOSDeclarationID]
    public let families: [MOSModelFamily]
    public let retainedBytes: UInt64
    private let symbolIndex: [String: MOSSymbolID]

    package init(symbols: [String], scopes: [MOSScopeDeclaration], declarations: [MOSModelDeclaration],
                 programs: [MOSExpressionProgram], bindings: [MOSBindingDeclaration],
                 functions: [MOSFunctionDeclaration], exactDeclarationIDs: [MOSDeclarationID],
                 familyDeclarationIDs: [MOSDeclarationID], families: [MOSModelFamily],
                 symbolIndex: [String: MOSSymbolID], retainedBytes: UInt64) {
        self.symbols = symbols; self.scopes = scopes; self.declarations = declarations
        self.programs = programs; self.bindings = bindings; self.functions = functions
        self.exactDeclarationIDs = exactDeclarationIDs; self.familyDeclarationIDs = familyDeclarationIDs
        self.families = families; self.symbolIndex = symbolIndex; self.retainedBytes = retainedBytes
    }
    public func sameStorage(as other: MOSDeclarationSnapshot) -> Bool { self === other }
    public func symbol(named normalizedName: String) -> MOSSymbolID? { symbolIndex[normalizedName] }
    public func name(of id: MOSSymbolID) throws(MOSResolutionFailure) -> String {
        guard Int(id.rawValue) < symbols.count else { throw .invalidReference(table: "symbols", index: id.rawValue) }
        return symbols[Int(id.rawValue)]
    }
    public func scope(_ id: MOSScopeID) throws(MOSResolutionFailure) -> MOSScopeDeclaration {
        guard Int(id.rawValue) < scopes.count else { throw .invalidReference(table: "scopes", index: id.rawValue) }
        return scopes[Int(id.rawValue)]
    }
    public func declaration(_ id: MOSDeclarationID) throws(MOSResolutionFailure) -> MOSModelDeclaration {
        guard Int(id.rawValue) < declarations.count else { throw .invalidReference(table: "declarations", index: id.rawValue) }
        return declarations[Int(id.rawValue)]
    }
    public func program(_ id: MOSProgramID) throws(MOSResolutionFailure) -> MOSExpressionProgram {
        guard Int(id.rawValue) < programs.count else { throw .invalidReference(table: "programs", index: id.rawValue) }
        return programs[Int(id.rawValue)]
    }
    public func binding(_ id: MOSBindingID) throws(MOSResolutionFailure) -> MOSBindingDeclaration {
        guard Int(id.rawValue) < bindings.count else { throw .invalidReference(table: "bindings", index: id.rawValue) }
        return bindings[Int(id.rawValue)]
    }
    public func function(_ id: MOSFunctionID) throws(MOSResolutionFailure) -> MOSFunctionDeclaration {
        guard Int(id.rawValue) < functions.count else { throw .invalidReference(table: "functions", index: id.rawValue) }
        return functions[Int(id.rawValue)]
    }
    /// Slices retain the immutable backing without materializing candidate arrays.
    public func exact(named name: MOSSymbolID, in scope: MOSScopeID) -> ArraySlice<MOSDeclarationID> {
        let lower = boundary(name: name, scope: scope, upper: false)
        let upper = boundary(name: name, scope: scope, upper: true)
        return exactDeclarationIDs[lower..<upper]
    }
    public func family(named name: MOSSymbolID, in scope: MOSScopeID) -> ArraySlice<MOSDeclarationID> {
        var low = 0; var high = families.count
        while low < high {
            let middle = low + (high - low) / 2
            let entry = families[middle]
            if entry.scope.rawValue < scope.rawValue ||
                (entry.scope == scope && entry.name.rawValue < name.rawValue) { low = middle + 1 }
            else { high = middle }
        }
        guard low < families.count, families[low].scope == scope, families[low].name == name else {
            return familyDeclarationIDs[0..<0]
        }
        return familyDeclarationIDs[families[low].range]
    }
    private func boundary(name: MOSSymbolID, scope: MOSScopeID, upper: Bool) -> Int {
        var low = 0; var high = exactDeclarationIDs.count
        while low < high {
            let middle = low + (high - low) / 2
            let entry = declarations[Int(exactDeclarationIDs[middle].rawValue)]
            if entry.scope.rawValue < scope.rawValue ||
                (entry.scope == scope && (entry.name.rawValue < name.rawValue || (upper && entry.name == name))) {
                low = middle + 1
            } else { high = middle }
        }
        return low
    }
}
