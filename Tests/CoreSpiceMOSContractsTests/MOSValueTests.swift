import CoreSpiceMOSContracts
import Testing

@Suite("Portable MOS values")
struct MOSValueTests {
    @Test func programsRetainUniqueLexicalDependenciesAndBoundMetadata() throws {
        let limits = try limits()
        let expression = MOSExpression.conditional(condition: .reference(.init(0)),
            then: .function(.init(2), arguments: [.reference(.init(1)), .reference(.init(1))]),
            else: .literal(0))
        let program = try MOSExpressionProgram(id: .init(0), expression: expression, limits: limits)
        #expect(program.nodeCount == 6)
        #expect(program.maximumDepth == 3)
        #expect(program.dependencies == [.init(0), .init(1)])
        #expect(program.referencedFunctions == [.init(2)])
        #expect(throws: MOSResolutionFailure.limitExceeded(.expressionNodes)) {
            try MOSExpressionProgram(id: .init(0), expression: expression, limits: self.limits(nodes: 2))
        }
        #expect(throws: MOSResolutionFailure.invalidRequest) {
            try MOSExpressionProgram(id: .init(0), expression: .literal(.infinity), limits: limits)
        }
    }

    @Test func checkedResultsRetainSourceSymbolsAndOmittedGeometry() throws {
        let source = MOSSourceOccurrence(captureID: "opaque-capture", occurrenceID: 7, path: "model.sp",
            line: 12, column: 1, statementByteOffset: 128, statementOrdinal: 5)
        let result = try ResolvedMOSInstance(source: source, instanceSource: nil, selectedName: .init(0),
            symbolNames: ["nm", "vth0"], scope: .init(2), scopeInstantiation: 99, instance: "x1.m1",
            declaration: .init(3), polarity: .nmos, release: .bsim4_4_5,
            releaseOrigin: .explicit("4.5"), schema: MOSModelRelease.bsim4_4_5.schemaIdentity,
            modelCoefficients: [.init(symbol: .init(1), value: 0.7)], instanceParameters: [],
            rawGeometry: .init(length: nil, width: nil), normalizedGeometry: .init(length: nil, width: nil),
            selectionGeometry: .init(length: nil, width: nil, fingerDivisor: 1),
            profile: .coreStrictV1, rules: [.exactName], candidates: [.init(declaration: .init(3), disposition: .selected)], limits: try limits())
        #expect(result.source == source)
        #expect(result.symbolNames[Int(result.modelCoefficients[0].symbol.rawValue)] == "vth0")
        #expect(result.normalizedGeometry.length == nil)
        #expect(result.instanceParameters.isEmpty)
        #expect(result.scopeInstantiation == 99)
    }

    @Test func requestsRejectDuplicateSuppliedParametersWithoutInventingDefaults() throws {
        #expect(throws: MOSResolutionFailure.duplicateParameter(.init(2))) {
            try MOSResolutionRequest(instance: "m1", scope: .init(0), scopeInstantiation: 1,
                modelReference: .init(0), profile: .coreStrictV1,
                bindings: [.init(symbol: .init(2), program: .init(0)), .init(symbol: .init(2), program: .init(1))],
                parameterOverrides: [], geometryScale: 1, seed: 7, limits: try self.limits())
        }
    }

    @Test func programScratchAndRetainedCapacityRespectBudget() throws {
        let expression = MOSExpression.function(.init(0), arguments: Array(repeating: .reference(.init(1)), count: 32))
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try MOSExpressionProgram(id: .init(0), expression: expression, limits: self.limits(bytes: 64))
        }
        let program = try MOSExpressionProgram(id: .init(0), expression: expression, limits: limits())
        #expect(program.retainedBytes <= program.peakOwnedBufferBytes)
        #expect(program.peakOwnedBufferBytes <= 1_000_000)
        #expect(program.retainedBytes >= UInt64(program.dependencies.capacity * MemoryLayout<MOSSymbolID>.stride +
            program.referencedFunctions.capacity * MemoryLayout<MOSSymbolID>.stride))
        #expect(program.dependencies == [.init(1)])
        #expect(program.referencedFunctions == [.init(0)])
    }

    @Test func requestSourceRetentionRefusesOversizedPayload() throws {
        let source = MOSSourceOccurrence(captureID: nil, occurrenceID: nil,
            path: String(repeating: "p", count: 1_048_576), line: nil, column: nil,
            statementByteOffset: nil, statementOrdinal: nil)
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try MOSResolutionRequest(source: source, instance: "m1", scope: .init(0), scopeInstantiation: 1,
                modelReference: .init(0), profile: .coreStrictV1, bindings: [], parameterOverrides: [],
                geometryScale: 1, seed: 7, limits: try self.limits(bytes: 1024))
        }
    }

    @Test func checkedResultRefusesOversizedSourceBeforeRetention() throws {
        let source = MOSSourceOccurrence(captureID: String(repeating: "c", count: 1_048_576),
            occurrenceID: nil, path: nil, line: nil, column: nil, statementByteOffset: nil, statementOrdinal: nil)
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try ResolvedMOSInstance(source: source, instanceSource: nil, selectedName: .init(0),
                symbolNames: ["nm"], scope: .init(0), scopeInstantiation: 1, instance: "m1",
                declaration: .init(0), polarity: .nmos, release: .level1,
                releaseOrigin: .defaulted(.coreStrictV1), schema: MOSModelRelease.level1.schemaIdentity,
                modelCoefficients: [], instanceParameters: [],
                rawGeometry: .init(length: nil, width: nil), normalizedGeometry: .init(length: nil, width: nil),
                selectionGeometry: .init(length: nil, width: nil, fingerDivisor: 1),
                profile: .coreStrictV1, rules: [], candidates: [.init(declaration: .init(0), disposition: .selected)],
                limits: try self.limits(bytes: 1024))
        }
    }

    private func limits(nodes: Int = 64, bytes: UInt64 = 1_000_000) throws(MOSResolutionFailure) -> MOSResolutionLimits {
        try MOSResolutionLimits(maximumRetainedBytes: bytes, maximumDiagnosticBytes: 1024, maximumScopeDepth: 16,
            maximumSymbols: 64, maximumScopes: 16, maximumDeclarations: 64, maximumPrograms: 64,
            maximumBindings: 64, maximumFunctions: 16, maximumExpressionNodes: nodes, maximumExpressionDepth: 16,
            maximumCandidates: 64, maximumCacheEntries: 64, maximumEvaluationSteps: 1_000)
    }
}
