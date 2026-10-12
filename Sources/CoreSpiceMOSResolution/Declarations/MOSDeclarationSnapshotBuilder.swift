import CoreSpiceMOSContracts

/// Exclusive construction; immutable publication retains every declaration occurrence.
public struct MOSDeclarationSnapshotBuilder: ~Copyable {
    private struct Scope {
        let id: MOSScopeID
        let parent: MOSScopeID?
        let source: MOSSourceOccurrence?
        let depth: Int
        var bindings: [MOSBindingID] = []
        var functions: [MOSFunctionID] = []
    }
    private let limits: MOSResolutionLimits
    private let control: (any MOSResolutionControlling)?
    private var symbols: [String] = []
    private var symbolIndex: [String: MOSSymbolID] = [:]
    private var scopes: [Scope] = []
    private var declarations: [MOSModelDeclaration] = []
    private var programs: [MOSExpressionProgram] = []
    private var bindings: [MOSBindingDeclaration] = []
    private var functions: [MOSFunctionDeclaration] = []
    private var storage: MOSStorageBudget
    private var constructionSteps: UInt64 = 0
    private var failure: MOSResolutionFailure?

    /// Current retained payload and element capacities; allocator metadata is excluded.
    public var retainedBytes: UInt64 { storage.bytes }

    public init(limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil) {
        self.limits = limits; self.control = control
        storage = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps, control: control)
    }
    public mutating func intern(_ name: String) throws(MOSResolutionFailure) -> MOSSymbolID {
        try requireActive()
        try control?.checkCancellation()
        guard !name.isEmpty else { throw invalidIdentifier(name) }
        var byteCount: UInt64 = 0
        for byte in name.utf8 {
            try spend(.identifierBytes, units: 1)
            guard (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                  byte == 95 || byte == 46 || byte == 58 || byte == 36 else { throw invalidIdentifier(name) }
            guard byteCount < limits.maximumRetainedBytes - storage.bytes else { throw .limitExceeded(.retainedBytes) }
            byteCount += 1
        }
        // This temporary normalized payload is checked before allocating it.
        try storage.checkAdding(byteCount)
        var normalized = ""
        normalized.reserveCapacity(Int(byteCount))
        for byte in name.utf8 {
            try spend(.identifierBytes, units: 1)
            normalized.append(Character(UnicodeScalar(byte >= 65 && byte <= 90 ? byte + 32 : byte)))
        }
        if let existing = symbolIndex[normalized] { return existing }
        let id = MOSSymbolID(try index(symbols.count, maximum: limits.maximumSymbols, kind: .symbols))
        let payload = try sum(byteCount, byteCount) // Symbols and dictionary keys retain separate references.
        let dictionaryGrowth = try MOSStorageBudget.dictionaryGrowthBytes(symbolIndex, required: symbolIndex.count + 1)
        try preflight(payload, growth: try sum(MOSStorageBudget.growthBytes(symbols, required: symbols.count + 1), dictionaryGrowth))
        try admit(payload)
        try Self.reserve(&symbols, storage: &storage, failure: &failure, required: symbols.count + 1)
        try reserveDictionary(required: symbolIndex.count + 1)
        symbols.append(normalized); symbolIndex[normalized] = id
        return id
    }
    public mutating func addScope(parent: MOSScopeID?, source: MOSSourceOccurrence? = nil) throws(MOSResolutionFailure) -> MOSScopeID {
        try requireActive()
        let id = MOSScopeID(try index(scopes.count, maximum: limits.maximumScopes, kind: .scopes))
        var depth = 1
        if let parent { try requireScope(parent); depth = scopes[Int(parent.rawValue)].depth + 1 }
        guard depth <= limits.maximumScopeDepth else { throw .limitExceeded(.scopeDepth) }
        let payload = try textPayload(source: source)
        try preflight(payload, growth: MOSStorageBudget.growthBytes(scopes, required: scopes.count + 1))
        try admit(payload)
        try Self.reserve(&scopes, storage: &storage, failure: &failure, required: scopes.count + 1)
        scopes.append(Scope(id: id, parent: parent, source: source, depth: depth))
        return id
    }
    public mutating func addProgram(_ expression: MOSExpression) throws(MOSResolutionFailure) -> MOSProgramID {
        try requireActive()
        let id = MOSProgramID(try index(programs.count, maximum: limits.maximumPrograms, kind: .programs))
        let program = try MOSExpressionProgram(id: id, expression: expression, limits: limits,
            availableBytes: limits.maximumRetainedBytes - storage.bytes,
            workUsed: &constructionSteps, control: control)
        for symbol in program.dependencies { try spend(.expressionNodes, units: 1); try requireSymbol(symbol) }
        for symbol in program.referencedFunctions { try spend(.expressionNodes, units: 1); try requireSymbol(symbol) }
        let payload = program.retainedBytes - UInt64(MemoryLayout<MOSExpressionProgram>.stride)
        let required = programs.count + 1
        let growth = required > programs.capacity ? try MOSStorageBudget.growthBytes(programs, required: required) : 0
        try preflight(payload, growth: growth)
        try admit(payload)
        // This private table cannot share backing before the builder's consuming finish.
        do { try storage.reserveExclusive(&programs, required: required) }
        catch { failure = error; throw error }
        programs.append(program)
        return id
    }
    private func nameForBinding(_ symbol: MOSSymbolID) throws(MOSResolutionFailure) -> String {
        try requireSymbol(symbol)
        return symbols[Int(symbol.rawValue)]
    }
    public mutating func addBinding(symbol: MOSSymbolID, scope: MOSScopeID, program: MOSProgramID,
                                   source: MOSSourceOccurrence? = nil) throws(MOSResolutionFailure) -> MOSBindingID {
        try requireActive()
        if try nameForBinding(symbol) == "temper" { throw .reservedParameter(symbol) }
        try requireSymbol(symbol); try requireScope(scope); try requireProgram(program)
        let id = MOSBindingID(try index(bindings.count, maximum: limits.maximumBindings, kind: .bindings))
        let position = Int(scope.rawValue)
        var scopeBindings = scopes[position].bindings
        let payload = try textPayload(source: source)
        let growth = try sum(MOSStorageBudget.growthBytes(bindings, required: bindings.count + 1),
            MOSStorageBudget.growthBytes(scopeBindings, required: scopeBindings.count + 1))
        try preflight(payload, growth: sum(growth, MOSStorageBudget.growthBytes(scopes, required: scopes.count)))
        try admit(payload)
        // A copied builder may share the scope table. Admit its potential COW replacement.
        try Self.reserve(&scopes, storage: &storage, failure: &failure, required: scopes.count)
        try Self.reserve(&bindings, storage: &storage, failure: &failure, required: bindings.count + 1)
        try Self.reserve(&scopeBindings, storage: &storage, failure: &failure, required: scopeBindings.count + 1)
        bindings.append(MOSBindingDeclaration(id: id, symbol: symbol, scope: scope, program: program, source: source))
        scopeBindings.append(id); scopes[position].bindings = scopeBindings
        return id
    }
    public mutating func addFunction(symbol: MOSSymbolID, scope: MOSScopeID, parameters: [MOSSymbolID],
                                    program: MOSProgramID, source: MOSSourceOccurrence? = nil) throws(MOSResolutionFailure) -> MOSFunctionID {
        try requireActive()
        try requireSymbol(symbol); try requireScope(scope); try requireProgram(program)
        let payload = try textPayload(source: source,
            additional: MOSStorageBudget.capacityBytes(parameters.capacity, of: MOSSymbolID.self))
        try validateParameters(parameters)
        let id = MOSFunctionID(try index(functions.count, maximum: limits.maximumFunctions, kind: .functions))
        let position = Int(scope.rawValue)
        var scopeFunctions = scopes[position].functions
        let growth = try sum(MOSStorageBudget.growthBytes(functions, required: functions.count + 1),
            MOSStorageBudget.growthBytes(scopeFunctions, required: scopeFunctions.count + 1))
        try preflight(payload, growth: sum(growth, MOSStorageBudget.growthBytes(scopes, required: scopes.count)))
        try admit(payload)
        try Self.reserve(&scopes, storage: &storage, failure: &failure, required: scopes.count)
        try Self.reserve(&functions, storage: &storage, failure: &failure, required: functions.count + 1)
        try Self.reserve(&scopeFunctions, storage: &storage, failure: &failure, required: scopeFunctions.count + 1)
        functions.append(MOSFunctionDeclaration(id: id, symbol: symbol, scope: scope, parameters: parameters, program: program, source: source))
        scopeFunctions.append(id); scopes[position].functions = scopeFunctions
        return id
    }
    public mutating func addModel(name: String, scope: MOSScopeID, polarity: MOSPolarity,
                                 level: Int?, version: String?, coefficients: [MOSExpressionBinding],
                                 source: MOSSourceOccurrence, invalidCoefficient: MOSSymbolID? = nil) throws(MOSResolutionFailure) -> MOSDeclarationID {
        try requireActive(); try requireScope(scope)
        for coefficient in coefficients { try spend(.declarations, units: 1); try requireSymbol(coefficient.symbol); try requireProgram(coefficient.program) }
        if let invalidCoefficient { try spend(.declarations, units: 1); try requireSymbol(invalidCoefficient) }
        let payload = try textPayload(source: source, first: name, second: version,
            additional: MOSStorageBudget.capacityBytes(coefficients.capacity, of: MOSExpressionBinding.self))
        let id = MOSDeclarationID(try index(declarations.count, maximum: limits.maximumDeclarations, kind: .declarations))
        let symbol = try intern(name)
        let normalized = symbols[Int(symbol.rawValue)]
        var family: MOSSymbolID?
        var lastDot: String.Index?
        for position in normalized.indices { try spend(.identifierBytes, units: 1); if normalized[position] == "." { lastDot = position } }
        if let dot = lastDot, dot != normalized.startIndex {
            let suffix = normalized[normalized.index(after: dot)...]
            var digits = !suffix.isEmpty
            for byte in suffix.utf8 { try spend(.identifierBytes, units: 1); if !(48...57).contains(byte) { digits = false } }
            if digits { family = try intern(String(normalized[..<dot])) }
        }
        try preflight(payload, growth: MOSStorageBudget.growthBytes(declarations, required: declarations.count + 1))
        try admit(payload)
        try Self.reserve(&declarations, storage: &storage, failure: &failure, required: declarations.count + 1)
        declarations.append(MOSModelDeclaration(id: id, name: symbol, originalName: name, family: family,
            scope: scope, polarity: polarity, level: level, version: version, coefficients: coefficients, invalidCoefficient: invalidCoefficient, source: source))
        return id
    }
    public consuming func finish() throws(MOSResolutionFailure) -> MOSDeclarationSnapshot {
        try requireActive(); try control?.checkCancellation()
        // Output buffers are local. A failed finish releases them and never changes the retained ledger.
        var output = storage
        var exact: [MOSDeclarationID] = []
        var familyIDs: [MOSDeclarationID] = []
        try output.reserve(&exact, required: declarations.count)
        try output.reserve(&familyIDs, required: declarations.count)
        for declaration in declarations {
            try spend(.indexEntries, units: 1)
            exact.append(declaration.id)
            if declaration.family != nil { familyIDs.append(declaration.id) }
        }
        try sort(&exact, family: false); try sort(&familyIDs, family: true)
        var families: [MOSModelFamily] = []
        var position = 0
        while position < familyIDs.count {
            let first = declarations[Int(familyIDs[position].rawValue)]
            let start = position
            while position < familyIDs.count {
                try spend(.indexEntries, units: 1)
                let next = declarations[Int(familyIDs[position].rawValue)]
                if next.scope != first.scope || next.family != first.family { break }
                position += 1
            }
            guard position - start <= limits.maximumCandidates else { throw .limitExceeded(.candidates) }
            try output.reserve(&families, required: families.count + 1)
            families.append(MOSModelFamily(scope: first.scope, name: first.family!, range: start..<position))
        }
        var finalScopes: [MOSScopeDeclaration] = []
        try output.reserve(&finalScopes, required: scopes.count)
        for scope in scopes {
            try spend(.scopes, units: 1)
            finalScopes.append(MOSScopeDeclaration(id: scope.id, parent: scope.parent, source: scope.source,
                parameterBindings: scope.bindings, functions: scope.functions))
        }
        // The snapshot retains the final scope array, not the private construction scope array.
        output.release(try MOSStorageBudget.capacityBytes(scopes.capacity, of: Scope.self))
        return MOSDeclarationSnapshot(symbols: symbols, scopes: finalScopes, declarations: declarations,
            programs: programs, bindings: bindings, functions: functions, exactDeclarationIDs: exact,
            familyDeclarationIDs: familyIDs, families: families, symbolIndex: symbolIndex, retainedBytes: output.bytes)
    }
    private mutating func validateParameters(_ parameters: [MOSSymbolID]) throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes - storage.bytes,
            maximumSteps: limits.maximumEvaluationSteps - constructionSteps, control: control)
        defer { constructionSteps += budget.steps }
        var seen = Set<MOSSymbolID>()
        try budget.reserveSet(&seen, required: parameters.count)
        for parameter in parameters {
            try budget.spend(); try requireSymbol(parameter)
            guard seen.insert(parameter).inserted else { throw .duplicateParameter(parameter) }
        }
    }
    private mutating func textPayload(source: MOSSourceOccurrence?, first: String? = nil, second: String? = nil,
                                     additional: UInt64 = 0) throws(MOSResolutionFailure) -> UInt64 {
        let available = limits.maximumRetainedBytes - storage.bytes
        guard additional <= available else { throw .limitExceeded(.retainedBytes) }
        var bytes = additional
        func count(_ text: String?) throws(MOSResolutionFailure) {
            guard let text else { return }
            for _ in text.utf8 {
                try spend(.identifierBytes, units: 1)
                guard bytes < available else { throw .limitExceeded(.retainedBytes) }
                bytes += 1
            }
        }
        if let source { try count(source.captureID); try count(source.path) }
        try count(first); try count(second)
        return bytes
    }
    private mutating func preflight(_ payload: UInt64, growth: UInt64) throws(MOSResolutionFailure) {
        try storage.checkAdding(sum(payload, growth))
    }
    private static func reserve<Element>(_ values: inout [Element], storage: inout MOSStorageBudget,
                                         failure: inout MOSResolutionFailure?, required: Int) throws(MOSResolutionFailure) {
        do { try storage.reserve(&values, required: required) }
        catch { failure = error; throw error }
    }
    private mutating func reserveDictionary(required: Int) throws(MOSResolutionFailure) {
        do { try storage.reserveDictionary(&symbolIndex, required: required) }
        catch { failure = error; throw error }
    }
    private mutating func admit(_ bytes: UInt64) throws(MOSResolutionFailure) {
        do { try storage.add(bytes) }
        catch { failure = error; throw error }
    }
    private func requireActive() throws(MOSResolutionFailure) { if let failure { throw failure } }
    private func sum(_ lhs: UInt64, _ rhs: UInt64) throws(MOSResolutionFailure) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw .arithmeticOverflow }; return result
    }
    private mutating func invalidIdentifier(_ name: String) -> MOSResolutionFailure {
        var bytes: UInt64 = 0
        for _ in name.utf8 {
            if bytes >= limits.maximumDiagnosticBytes { return .limitExceeded(.diagnosticBytes) }
            do { try spend(.diagnosticBytes, units: 1) } catch { return error }
            bytes += 1
        }
        return .invalidIdentifier(name)
    }
    /// In-place heap sort preserves the typed work/cancellation failure contract.
    private mutating func sort(_ values: inout [MOSDeclarationID], family: Bool) throws(MOSResolutionFailure) {
        guard values.count > 1 else { return }
        func less(_ lhs: MOSDeclarationID, _ rhs: MOSDeclarationID) throws(MOSResolutionFailure) -> Bool {
            try spend(.indexEntries, units: 1)
            return ordered(lhs, rhs, family: family)
        }
        func sift(_ start: Int, end: Int) throws(MOSResolutionFailure) {
            var root = start
            while root < end / 2 {
                var child = root * 2 + 1
                if child + 1 < end, try less(values[child], values[child + 1]) { child += 1 }
                guard try less(values[root], values[child]) else { return }
                values.swapAt(root, child); root = child
            }
        }
        for start in (0..<(values.count / 2)).reversed() { try sift(start, end: values.count) }
        for end in (1..<values.count).reversed() { values.swapAt(0, end); try sift(0, end: end) }
    }
    private func ordered(_ lhs: MOSDeclarationID, _ rhs: MOSDeclarationID, family: Bool) -> Bool {
        let a = declarations[Int(lhs.rawValue)]; let b = declarations[Int(rhs.rawValue)]
        if a.scope != b.scope { return a.scope.rawValue < b.scope.rawValue }
        let an = family ? a.family! : a.name; let bn = family ? b.family! : b.name
        if an != bn { return an.rawValue < bn.rawValue }; return lhs.rawValue < rhs.rawValue
    }
    private mutating func index(_ count: Int, maximum: Int, kind: MOSResolutionWork) throws(MOSResolutionFailure) -> UInt32 {
        try control?.checkCancellation()
        guard count < maximum else { throw .limitExceeded(kind) }
        guard let result = UInt32(exactly: count) else { throw .arithmeticOverflow }
        try spend(kind, units: 1); return result
    }
    private mutating func spend(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        let (next, overflow) = constructionSteps.addingReportingOverflow(units)
        guard !overflow, next <= limits.maximumEvaluationSteps else { throw .limitExceeded(.evaluationSteps) }
        try control?.checkCancellation(); try control?.charge(kind, units: units)
        constructionSteps = next
    }
    private func requireScope(_ id: MOSScopeID) throws(MOSResolutionFailure) {
        guard Int(id.rawValue) < scopes.count else { throw .invalidReference(table: "scopes", index: id.rawValue) }
    }
    private func requireProgram(_ id: MOSProgramID) throws(MOSResolutionFailure) {
        guard Int(id.rawValue) < programs.count else { throw .invalidReference(table: "programs", index: id.rawValue) }
    }
    private func requireSymbol(_ id: MOSSymbolID) throws(MOSResolutionFailure) {
        guard Int(id.rawValue) < symbols.count else { throw .invalidReference(table: "symbols", index: id.rawValue) }
    }
}
