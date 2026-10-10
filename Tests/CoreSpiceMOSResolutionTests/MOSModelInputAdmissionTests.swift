import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("MOS model input admission", .timeLimit(.minutes(1)))
struct MOSModelInputAdmissionTests {
    @Test func markedDeclarationRefusesWithoutEvaluatingCoefficientPrograms() throws {
        var fixture = try MOSSelectionFixture()
        let bad = try fixture.builder.intern("vth0")
        let rand = try fixture.builder.intern("rand")
        let random = try fixture.builder.addProgram(.function(rand, arguments: []))
        _ = try fixture.builder.addModel(name: "n", scope: fixture.root, polarity: .nmos,
            level: 54, version: "4.8.3", coefficients: [.init(symbol: bad, program: random)],
            source: MOSSelectionFixture.source("original-card"), invalidCoefficient: bad)
        let snapshot = try fixture.finish()
        #expect(snapshot.declarations[0].invalidCoefficient == bad)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: fixture.graph(snapshot), seed: 42, limits: fixture.limits)
        #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "vth0"))) {
            _ = try resolveMOS(fixture.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        }
        #expect(session.randomDraws == 0)
        #expect(session.failureDiagnostic?.candidateRange != nil)
        #expect(session.failureDiagnostic?.snapshot.declarations[0].source.path == "original-card")
    }

    @Test func discardedDuplicateMarkerDoesNotInvalidatePinnedFirstCard() throws {
        var fixture = try MOSSelectionFixture()
        _ = try fixture.bin("n")
        let bad = try fixture.builder.intern("vth0")
        _ = try fixture.builder.addModel(name: "n", scope: fixture.root, polarity: .nmos,
            level: 54, version: "4.8.3", coefficients: [], source: MOSSelectionFixture.source("discarded"), invalidCoefficient: bad)
        let snapshot = try fixture.finish()
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: fixture.graph(snapshot), seed: 42, limits: fixture.limits)
        let result = try resolveMOS(fixture.request([], profile: .pinnedNgspiceNormalV1), from: snapshot,
            schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.declaration == MOSDeclarationID(0))
        #expect(try inspectResolvedMOS(result, from: snapshot, limits: fixture.limits).declaration == result.declaration)
    }

    @Test func markerRequiresASnapshotOwnedSymbol() throws {
        var fixture = try MOSSelectionFixture()
        #expect(throws: MOSResolutionFailure.invalidReference(table: "symbols", index: UInt32.max)) {
            _ = try fixture.builder.addModel(name: "n", scope: fixture.root, polarity: .nmos,
                level: 54, version: "4.8.3", coefficients: [], source: MOSSelectionFixture.source("invalid"),
                invalidCoefficient: MOSSymbolID(UInt32.max))
        }
    }
}
