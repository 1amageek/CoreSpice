import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Ordered immutable MOS declaration snapshot")
struct MOSSnapshotTests {
    @Test func sourceOrderDuplicatesAndScopeGraphsSurviveIndexedPublication() throws {
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits())
        let global = try builder.addScope(parent: nil)
        let child = try builder.addScope(parent: global)
        let width = try builder.intern("W")
        #expect(try builder.intern("w") == width)
        let literal = try builder.addProgram(.literal(2e-6))
        let binding = try builder.addBinding(symbol: width, scope: child, program: literal)
        let functionName = try builder.intern("twice")
        let formal = try builder.intern("x")
        let body = try builder.addProgram(.binary(.multiply, .literal(2), .reference(formal)))
        let function = try builder.addFunction(symbol: functionName, scope: child, parameters: [formal], program: body)
        var expected: [MOSDeclarationID] = []
        for (index, name) in ["NM.2", "other", "nm.1", "NM.2", "nm.a", "nm.", "nm.1.extra", "nm.01"].enumerated() {
            expected.append(try builder.addModel(name: name, scope: global, polarity: .nmos, level: 54, version: "4.5",
                coefficients: [], source: source(UInt64(index))))
        }
        let local = try builder.addModel(name: "nm.3", scope: child, polarity: .nmos, level: 54, version: "4.5",
            coefficients: [.init(symbol: width, program: literal)], source: source(99))
        let snapshot = try builder.finish()
        #expect(snapshot.declarations.map(\.id) == expected + [local])
        #expect(snapshot.declarations.map(\.source.occurrenceID) == (0..<8).map { Optional(UInt64($0)) } + [99])
        let name = try #require(snapshot.symbol(named: "nm"))
        #expect(Array(snapshot.family(named: name, in: global)) == [expected[0], expected[2], expected[3], expected[7]])
        #expect(Array(snapshot.family(named: name, in: child)) == [local])
        let exact = try #require(snapshot.symbol(named: "nm.2"))
        #expect(Array(snapshot.exact(named: exact, in: global)) == [expected[0], expected[3]])
        #expect(try snapshot.scope(child).parameterBindings == [binding])
        #expect(try snapshot.scope(child).functions == [function])
        #expect(try snapshot.binding(binding).scope == child)
        #expect(try snapshot.function(function).parameters == [formal])
        #expect(snapshot.sameStorage(as: snapshot))
        let capacities = snapshot.symbols.capacity * MemoryLayout<String>.stride +
            snapshot.scopes.capacity * MemoryLayout<MOSScopeDeclaration>.stride +
            snapshot.declarations.capacity * MemoryLayout<MOSModelDeclaration>.stride +
            snapshot.programs.capacity * MemoryLayout<MOSExpressionProgram>.stride +
            snapshot.bindings.capacity * MemoryLayout<MOSBindingDeclaration>.stride +
            snapshot.functions.capacity * MemoryLayout<MOSFunctionDeclaration>.stride +
            snapshot.exactDeclarationIDs.capacity * MemoryLayout<MOSDeclarationID>.stride +
            snapshot.familyDeclarationIDs.capacity * MemoryLayout<MOSDeclarationID>.stride +
            snapshot.families.capacity * MemoryLayout<MOSModelFamily>.stride
        #expect(UInt64(capacities) <= snapshot.retainedBytes)
        #expect(snapshot.retainedBytes <= 1_000_000)
        var other = MOSDeclarationSnapshotBuilder(limits: try limits())
        _ = try other.addScope(parent: nil)
        let otherSnapshot = try other.finish()
        #expect(!snapshot.sameStorage(as: otherSnapshot))
    }

    @Test func invalidReferencesAndBudgetsRefuseBeforePublication() throws {
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(scopeDepth: 1))
        let global = try builder.addScope(parent: nil)
        #expect(throws: MOSResolutionFailure.limitExceeded(.scopeDepth)) { try builder.addScope(parent: global) }
        #expect(throws: MOSResolutionFailure.invalidReference(table: "symbols", index: 9)) {
            try builder.addProgram(.reference(.init(9)))
        }
        let snapshot = try builder.finish()
        #expect(snapshot.programs.isEmpty)
        #expect(throws: MOSResolutionFailure.invalidReference(table: "declarations", index: 0)) {
            try snapshot.declaration(.init(0))
        }
        var tiny = MOSDeclarationSnapshotBuilder(limits: try limits(bytes: 1))
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) { try tiny.intern("model") }
        var cancelled = MOSDeclarationSnapshotBuilder(limits: try limits(), control: CancelledMOSConstruction())
        #expect(throws: MOSResolutionFailure.cancelled) { try cancelled.addScope(parent: nil) }
    }

    @Test func sourcePayloadIsAdmittedAtEveryDeclarationRetentionBoundary() throws {
        let large = MOSSourceOccurrence(captureID: nil, occurrenceID: nil,
            path: String(repeating: "p", count: 1_048_576), line: nil, column: nil,
            statementByteOffset: nil, statementOrdinal: nil)
        var scopeBuilder = MOSDeclarationSnapshotBuilder(limits: try limits(bytes: 1024, steps: 10_000))
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try scopeBuilder.addScope(parent: nil, source: large)
        }
        let emptyScopes = try scopeBuilder.finish()
        #expect(emptyScopes.scopes.isEmpty)
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(bytes: 1024, steps: 10_000))
        let scope = try builder.addScope(parent: nil)
        let name = try builder.intern("n")
        let program = try builder.addProgram(.literal(1))
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try builder.addBinding(symbol: name, scope: scope, program: program, source: large)
        }
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try builder.addFunction(symbol: name, scope: scope, parameters: [], program: program, source: large)
        }
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try builder.addModel(name: "n", scope: scope, polarity: .nmos, level: 1,
                version: nil, coefficients: [], source: large)
        }
        let snapshot = try builder.finish()
        #expect(snapshot.bindings.isEmpty && snapshot.functions.isEmpty && snapshot.declarations.isEmpty)
        #expect(snapshot.retainedBytes <= 1024)
    }

    @Test func programConstructionSharesTheBuilderWorkCeilingWithoutController() throws {
        var expression = MOSExpression.literal(0)
        for _ in 0..<29 { expression = .unary(.plus, expression) }
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(steps: 100))
        _ = try builder.addProgram(expression)
        #expect(throws: MOSResolutionFailure.limitExceeded(.evaluationSteps)) {
            for _ in 1..<10 { _ = try builder.addProgram(expression) }
        }
    }

    @Test func failedSourceAdmissionLeavesNoPhantomRetainedBytes() throws {
        let nearLimit = MOSSourceOccurrence(captureID: nil, occurrenceID: nil,
            path: String(repeating: "p", count: 1000), line: nil, column: nil,
            statementByteOffset: nil, statementOrdinal: nil)
        var reused = MOSDeclarationSnapshotBuilder(limits: try limits(bytes: 1024, steps: 10_000))
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try reused.addScope(parent: nil, source: nearLimit)
        }
        _ = try reused.addScope(parent: nil)
        var fresh = MOSDeclarationSnapshotBuilder(limits: try limits(bytes: 1024, steps: 10_000))
        _ = try fresh.addScope(parent: nil)
        let reusedSnapshot = try reused.finish(), freshSnapshot = try fresh.finish()
        #expect(reusedSnapshot.retainedBytes == freshSnapshot.retainedBytes)
    }

    @Test func indexSortComparisonPropagatesTypedWorkFailure() throws {
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(steps: 26))
        let scope = try builder.addScope(parent: nil)
        let origin = MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: nil,
            line: nil, column: nil, statementByteOffset: nil, statementOrdinal: nil)
        for _ in 0..<4 {
            _ = try builder.addModel(name: "m", scope: scope, polarity: .nmos,
                level: 1, version: nil, coefficients: [], source: origin)
        }
        do {
            _ = try builder.finish()
            Issue.record("Expected index sort work refusal")
        } catch let failure as MOSResolutionFailure { #expect(failure == .limitExceeded(.evaluationSteps)) }
    }

    @Test func functionParameterCapacityIsRejectedBeforeScratchGrowth() throws {
        let maximumBytes: UInt64 = 1_000_000
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(bytes: maximumBytes,
            steps: 2_000_000, symbols: 2_000))
        let scope = try builder.addScope(parent: nil)
        var parameters: [MOSSymbolID] = []
        for index in 0..<1_000 { parameters.append(try builder.intern("p\(index)")) }
        let program = try builder.addProgram(.literal(1))
        let padding = Int(maximumBytes - builder.retainedBytes - 2_000)
        let origin = MOSSourceOccurrence(captureID: nil, occurrenceID: nil,
            path: String(repeating: "p", count: padding), line: nil, column: nil,
            statementByteOffset: nil, statementOrdinal: nil)
        _ = try builder.addModel(name: "p0", scope: scope, polarity: .nmos, level: 1,
            version: nil, coefficients: [], source: origin)
        let before = builder.retainedBytes
        #expect(maximumBytes - before < 2_000)
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try builder.addFunction(symbol: parameters[0], scope: scope, parameters: parameters, program: program)
        }
        #expect(builder.retainedBytes == before)
        let snapshot = try builder.finish()
        #expect(snapshot.functions.isEmpty)
    }

    @Test func postReserveFailureClosesEveryMutationAndPublicationEntryPoint() throws {
        var builder = MOSDeclarationSnapshotBuilder(limits: try limits(), control: RejectMOSCapacityCharge())
        #expect(throws: MOSResolutionFailure.cancelled) { try builder.addScope(parent: nil) }
        #expect(throws: MOSResolutionFailure.cancelled) { try builder.intern("later") }
        #expect(throws: MOSResolutionFailure.cancelled) { try builder.addScope(parent: nil) }
        do {
            _ = try builder.finish()
            Issue.record("Failed construction published a snapshot")
        } catch let failure as MOSResolutionFailure { #expect(failure == .cancelled) }
    }

    private func source(_ occurrence: UInt64) -> MOSSourceOccurrence {
        MOSSourceOccurrence(captureID: "capture", occurrenceID: occurrence, path: "include.sp",
            line: Int(occurrence) + 1, column: 1, statementByteOffset: occurrence * 16, statementOrdinal: occurrence)
    }
    private func limits(scopeDepth: Int = 16, bytes: UInt64 = 1_000_000, steps: UInt64 = 1_000, symbols: Int = 64) throws(MOSResolutionFailure) -> MOSResolutionLimits {
        try MOSResolutionLimits(maximumRetainedBytes: bytes, maximumDiagnosticBytes: 1024, maximumScopeDepth: scopeDepth,
            maximumSymbols: symbols, maximumScopes: 16, maximumInvocations: 64, maximumInvocationBindings: 256,
            maximumDeclarations: 64, maximumPrograms: 64,
            maximumBindings: 64, maximumFunctions: 16, maximumFunctionDepth: 16,
            maximumExpressionNodes: 64, maximumExpressionDepth: 64,
            maximumCandidates: 64, maximumCacheEntries: 64, maximumEvaluationSteps: steps)
    }
}
private struct CancelledMOSConstruction: MOSResolutionControlling {
    func checkCancellation() throws(MOSResolutionFailure) { throw .cancelled }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) { throw .cancelled }
}


private struct RejectMOSCapacityCharge: MOSResolutionControlling {
    func checkCancellation() throws(MOSResolutionFailure) {}
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        if kind == .retainedBytes, units > 0 { throw .cancelled }
    }
}
