import CoreSpiceMOSContracts
@testable import CoreSpiceMOSResolution
@testable import CoreSpiceLowering
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("Immutable source provenance storage", .timeLimit(.minutes(1)))
struct ImmutableProvenanceStorageTests {
    @Test func actualBufferCapacityAndUTF8PayloadOutliveSessionStatistics() throws {
        var visits: [MOSRootVisit] = []
        visits.reserveCapacity(32)
        visits.append(.condition(.ambient, program: nil))
        var scalars: [NetlistSourceScalarOverride] = []
        scalars.reserveCapacity(16)
        scalars.append(try .init(instanceName: "hierarchical_電圧_source", parameterName: "resistance", value: 123))
        let evaluation = MOSEvaluationProvenance(environment: nil, seed: 17,
            randomGeneratorVersion: "rng-version", evaluatorVersion: "evaluator-version",
            randomDraws: 3, rootVisits: visits)
        var retained: NetlistEvaluationProvenance?
        do {
            let provenance = NetlistEvaluationProvenance(temperatures: .init(ambient: .callerDefault, nominal: .callerDefault),
                sourceScalars: scalars, profile: .coreStrictV1, evaluation: evaluation,
                evaluationSteps: 99, retainedBytes: 16 * 1024 * 1024, peakOwnedBufferBytes: 24 * 1024 * 1024)
            let rootBytes = UInt64(visits.capacity * MemoryLayout<MOSRootVisit>.stride
                + evaluation.randomGeneratorVersion.utf8.count + evaluation.evaluatorVersion.utf8.count)
            let scalarBytes = UInt64(scalars.capacity * MemoryLayout<NetlistSourceScalarOverride>.stride
                + scalars[0].instanceName.utf8.count + scalars[0].parameterName.utf8.count)
            #expect(try evaluation.retainedPayloadByteCount() == rootBytes)
            #expect(try provenance.retainedPayloadByteCount() == rootBytes + scalarBytes)
            #expect(visits.capacity > visits.count && scalars.capacity > scalars.count)
            retained = provenance
        }
        let result = try #require(retained)
        #expect(result.rootVisits == visits && result.sourceScalars == scalars)
        #expect(result.seed == 17 && result.randomDraws == 3 && result.evaluationSteps == 99)
        #expect(result.retainedBytes == 16 * 1024 * 1024 && result.peakOwnedBufferBytes == 24 * 1024 * 1024)
        #expect(try result.retainedPayloadByteCount() < 16 * 1024 * 1024)
    }

    @Test func realLoweringDiagnosticCapacityIsNotImmutableResultCapacity() async throws {
        let parsed = try await SPICEParser().parse(source: """
        Immutable provenance
        .param shared={1000+rand()}
        .temp 27
        V1 out 0 1
        R1 out 0 {shared}
        .end
        """).get()
        func lower(diagnosticBytes: UInt64) throws -> LoweredCircuit {
            let limits = try MOSResolutionLimits(maximumRetainedBytes: 8 * 1024 * 1024,
                maximumDiagnosticBytes: diagnosticBytes, maximumScopeDepth: 16,
                maximumSymbols: 128, maximumScopes: 32, maximumInvocations: 32,
                maximumInvocationBindings: 128, maximumDeclarations: 32, maximumPrograms: 128,
                maximumBindings: 128, maximumFunctions: 32, maximumFunctionDepth: 16,
                maximumExpressionNodes: 256, maximumExpressionDepth: 32, maximumCandidates: 128,
                maximumCacheEntries: 128, maximumEvaluationSteps: 100_000)
            let compiled = try NetlistLowering.compile(parsed, captureSourceScalars: true, limits: limits)
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 17)
            try session.lower()
            return try session.finish()
        }
        let small = try lower(diagnosticBytes: 4096).evaluationProvenance
        let large = try lower(diagnosticBytes: 1024 * 1024).evaluationProvenance
        #expect(large.retainedBytes > small.retainedBytes + 1024 * 512)
        #expect(try large.retainedPayloadByteCount() == small.retainedPayloadByteCount())
        #expect(large.rootVisits == small.rootVisits && large.sourceScalars == small.sourceScalars)
        #expect(large.randomDraws == 1 && large.randomDraws == small.randomDraws)
        #expect(!large.sourceScalars.isEmpty && large.evaluation.environment == small.evaluation.environment)
        #expect(try large.retainedPayloadByteCount() < 4096)
    }
}
