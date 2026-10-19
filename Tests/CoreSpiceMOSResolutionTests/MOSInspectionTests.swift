import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Independent held MOS evidence inspection")
struct MOSInspectionTests {
    @Test func heldRandomCoefficientInspectionConsumesNoDrawAndWrongIdentityRefusesFirst() throws {
        var f = try MOSSelectionFixture()
        let rand = try f.builder.intern("rand")
        let random = try f.builder.addProgram(.function(rand, arguments: []))
        let vto = try f.builder.intern("vto")
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
            version: nil, coefficients: [MOSExpressionBinding(symbol: vto, program: random)],
            source: MOSSelectionFixture.source("n"))
        let dims = try [f.binding("l", 1e-6), f.binding("w", 1e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(dims), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        let draws = session.randomDraws
        #expect(draws == 1)
        let inspection = try inspectResolvedMOS(result, from: snapshot, limits: f.limits)
        #expect(inspection.candidates == result.candidates && session.randomDraws == draws)
        #expect(result.candidates[0].bounds == nil)
        #expect(result.modelCoefficients.first { $0.symbol == vto }?.value.isFinite == true)
        var other = try MOSSelectionFixture()
        let unrelated = try other.finish()
        #expect(throws: MOSResolutionFailure.conditionMismatch) {
            try inspectResolvedMOS(result, from: unrelated, limits: f.limits, control: CancelMOSInspection())
        }
        _ = try evaluateMOSProgram(random, invocation: 1, lexicalScope: f.root, from: snapshot, session: &session)
        #expect(session.randomDraws == draws + 1)
    }



    @Test func inspectionHonorsCancellationOnMatchingSnapshot() throws {
        var f = try MOSSelectionFixture()
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
            version: nil, coefficients: [], source: MOSSelectionFixture.source("n"))
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        #expect(throws: MOSResolutionFailure.cancelled) {
            try inspectResolvedMOS(result, from: snapshot, limits: f.limits, control: CancelMOSInspection())
        }
    }
}

private struct CancelMOSInspection: MOSResolutionControlling {
    func checkCancellation() throws(MOSResolutionFailure) { throw .cancelled }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) { throw .cancelled }
}
