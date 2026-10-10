import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Independent held MOS evidence inspection")
struct MOSInspectionTests {
    @Test func heldRandomBoundsInspectionConsumesNoDrawAndWrongIdentityRefusesFirst() throws {
        var f = try MOSSelectionFixture()
        let rand = try f.builder.intern("rand")
        let random = try f.builder.addProgram(.function(rand, arguments: []))
        let lmin = try f.builder.intern("lmin")
        let bound = try f.builder.addProgram(.binary(.multiply, .literal(1e-9), .function(rand, arguments: [])))
        let rest = try [f.binding("lmax", 2e-6), f.binding("wmin", 0), f.binding("wmax", 2e-6)]
        _ = try f.builder.addModel(name: "n.1", scope: f.root, polarity: .nmos, level: 54,
            version: "4.8.3", coefficients: [MOSExpressionBinding(symbol: lmin, program: bound)] + rest,
            source: MOSSelectionFixture.source("n.1"))
        let dims = try [f.binding("l", 1e-6), f.binding("w", 1e-6)]
        let snapshot = try f.builder.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(dims), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        let draws = session.randomDraws
        #expect(draws == 1)
        let inspection = try inspectResolvedMOS(result, from: snapshot, limits: f.limits)
        #expect(inspection.candidates == result.candidates && session.randomDraws == draws)
        #expect(result.candidates[0].bounds?.lengthMinimum == result.modelCoefficients.first { $0.symbol == lmin }?.value)
        var other = try MOSSelectionFixture()
        let unrelated = try other.builder.finish()
        #expect(throws: MOSResolutionFailure.conditionMismatch) {
            try inspectResolvedMOS(result, from: unrelated, limits: f.limits, control: CancelMOSInspection())
        }
        _ = try evaluateMOSProgram(random, invocation: 1, lexicalScope: f.root, from: snapshot, session: &session)
        #expect(session.randomDraws == draws + 1)
    }

    @Test func perFingerInspectionPreservesOriginalScaleAtSubnormalRoundingBoundary() throws {
        var f = try MOSSelectionFixture()
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 54,
            version: "4.8.3", coefficients: [], source: MOSSelectionFixture.source("n"))
        let values = try [f.binding("w", 0.7), f.binding("nf", 1.4)]
        let snapshot = try f.builder.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(values, profile: .pinnedNgspiceNormalV1,
            scale: 2 * Double.leastNonzeroMagnitude, fingers: true), from: snapshot,
            schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.normalizedGeometry.width == Double.leastNonzeroMagnitude)
        #expect(result.selectionGeometry.width == Double.leastNonzeroMagnitude)
        let inspection = try inspectResolvedMOS(result, from: snapshot, limits: f.limits)
        #expect(inspection.declaration == result.declaration)
    }

    @Test func inspectionHonorsCancellationOnMatchingSnapshot() throws {
        var f = try MOSSelectionFixture()
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
            version: nil, coefficients: [], source: MOSSelectionFixture.source("n"))
        let snapshot = try f.builder.finish(), graph = try f.graph(snapshot)
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
