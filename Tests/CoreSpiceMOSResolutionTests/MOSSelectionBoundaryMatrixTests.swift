import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("MOS selection endpoint and invalid-candidate matrix")
struct MOSSelectionBoundaryMatrixTests {
    // Authority: Selection/DESIGN.md strict inclusive bounds, with no tolerance.
    // Endpoint indices select LMIN, LMAX, WMIN, WMAX; offsets are adjacent Doubles.
    @Test(arguments: [0, 1, 2, 3], [-1, 0, 1])
    func strictEndpointNeighborhoods(endpoint: Int, offset: Int) throws {
        var f = try MOSSelectionFixture()
        let name = "N.1"
        let model = try f.bin(name)
        let isLower = endpoint.isMultiple(of: 2)
        let bound = isLower ? 1e-6 : 2e-6
        let value = neighbor(bound, offset: offset)
        let axis = endpoint / 2
        let dimensions = try [f.binding("l", axis == 0 ? value : 1.5e-6),
                              f.binding("w", axis == 1 ? value : 1.5e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let request = try f.request(dimensions)
        let accepted = isLower ? offset >= 0 : offset <= 0
        if accepted {
            let result = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            #expect(result.declaration == model)
            #expect(result.source == MOSSelectionFixture.source(name))
            #expect(result.selectionGeometry.length == (axis == 0 ? value : 1.5e-6))
            #expect(result.selectionGeometry.width == (axis == 1 ? value : 1.5e-6))
            #expect(result.candidates[0].bounds == MOSBinBounds(lengthMinimum: 1e-6,
                lengthMaximum: 2e-6, widthMinimum: 1e-6, widthMaximum: 2e-6))
            let inspection = try inspectResolvedMOS(result, from: snapshot, limits: f.limits)
            #expect(inspection.declaration == model && inspection.candidates == result.candidates)
            #expect(session.randomDraws == 0)
        } else {
            #expect(throws: MOSResolutionFailure.noMatchingBin(f.model)) {
                try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
            #expect(throws: MOSResolutionFailure.poisonedSession) {
                try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
        }
    }

    // Authority: Selection/DESIGN.md rejects gaps and multiple current matches.
    // Separate bins have distinct source occurrences; neither a near bin nor a merge is allowed.
    @Test(arguments: [0, 1], [false, true])
    func strictGapsAndInteriorOverlaps(axis: Int, overlap: Bool) throws {
        var f = try MOSSelectionFixture()
        _ = try f.bin("n.1")
        var bounds: [Double?] = [1e-6, 2e-6, 1e-6, 2e-6]
        bounds[axis * 2] = overlap ? 1.5e-6 : 3e-6
        bounds[axis * 2 + 1] = overlap ? 3e-6 : 4e-6
        _ = try f.bin("n.2", bounds: bounds)
        let value = overlap ? 1.75e-6 : 2.5e-6
        let dimensions = try [f.binding("l", axis == 0 ? value : 1.5e-6),
                              f.binding("w", axis == 1 ? value : 1.5e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let failure: MOSResolutionFailure = overlap ? .ambiguousModel(f.model) : .noMatchingBin(f.model)
        #expect(throws: failure) {
            try resolveMOS(f.request(dimensions), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        }
        #expect(session.randomDraws == 0)
    }

    // Authority: Selection/DESIGN.md uses abs(distance) < 1e-9 meters, not <=.
    // A zero upper bound is allowed for model bounds; supplied geometry remains positive.
    // The lower-side construction uses exact doubling and checks represented subtraction.
    @Test(arguments: [0, 1, 2, 3], [-1, 0, 1])
    func pinnedToleranceNeighborhoods(endpoint: Int, offset: Int) throws {
        var f = try MOSSelectionFixture()
        let tolerance = 1e-9
        let isLower = endpoint.isMultiple(of: 2)
        let axis = endpoint / 2
        let coordinate = neighbor(tolerance, offset: isLower ? -offset : offset)
        let endpointValue = isLower ? 2 * tolerance : 0
        let distance = abs(coordinate - endpointValue)
        try #require(distance == neighbor(tolerance, offset: offset))
        var bounds: [Double?] = [1e-6, 2e-6, 1e-6, 2e-6]
        bounds[axis * 2] = endpointValue
        bounds[axis * 2 + 1] = isLower ? 4 * tolerance : 0
        let model = try f.bin("n.1", bounds: bounds)
        let dimensions = try [f.binding("l", axis == 0 ? coordinate : 1.5e-6),
                              f.binding("w", axis == 1 ? coordinate : 1.5e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let request = try f.request(dimensions, profile: .pinnedNgspiceNormalV1)
        if offset < 0 {
            let result = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            #expect(result.declaration == model && result.source == MOSSelectionFixture.source("n.1"))
            let inspection = try inspectResolvedMOS(result, from: snapshot, limits: f.limits)
            #expect(inspection.candidates == result.candidates)
        } else {
            #expect(throws: MOSResolutionFailure.noMatchingBin(f.model)) {
                try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
        }
        #expect(session.randomDraws == 0)
    }

    // Authority: Selection/DESIGN.md invalid visited bounds fail both profiles;
    // missing pinned bounds are excluded. Evaluation rejects nonfinite arithmetic.
    // The malformed card is visited even though a valid card can satisfy geometry:
    // strict traverses all cards, and pinned visits the last distinct registration first.
    @Test(arguments: Array(0..<6), [MOSInputProfile.coreStrictV1, .pinnedNgspiceNormalV1])
    func invalidVisitedBounds(caseIndex: Int, profile: MOSInputProfile) throws {
        var f = try MOSSelectionFixture()
        let valid = try f.bin("n.1")
        let axis = caseIndex / 3, kind = caseIndex % 3
        var bounds: [Double?] = [1e-6, 2e-6, 1e-6, 2e-6]
        var extras: [MOSExpressionBinding] = []
        if kind == 0 {
            bounds[axis * 2] = 3e-6
        } else {
            bounds[axis * 2] = nil
            if kind == 2 {
                let symbol = try f.builder.intern(axis == 0 ? "lmin" : "wmin")
                let program = try f.builder.addProgram(.binary(.multiply,
                    .literal(Double.greatestFiniteMagnitude), .literal(2)))
                extras.append(MOSExpressionBinding(symbol: symbol, program: program))
            }
        }
        let invalid = try f.bin("n.2", bounds: bounds, extras: extras)
        let dimensions = try [f.binding("l", 1.5e-6), f.binding("w", 1.5e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let request = try f.request(dimensions, profile: profile)
        if kind == 1 && profile == .pinnedNgspiceNormalV1 {
            let result = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            #expect(result.declaration == valid && result.source == MOSSelectionFixture.source("n.1"))
            #expect(result.candidates.map(\.declaration) == [invalid, valid])
            #expect(result.candidates.map(\.disposition) == [.missingBounds, .selected])
            #expect(result.candidates[0].bounds?.missingMask == (axis == 0 ? 1 : 4))
            let inspection = try inspectResolvedMOS(result, from: snapshot, limits: f.limits)
            #expect(inspection.candidates == result.candidates)
        } else {
            let failure: MOSResolutionFailure = kind == 2 ? .nonFiniteExpression : .invalidBin(invalid)
            #expect(throws: failure) {
                try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
            #expect(throws: MOSResolutionFailure.poisonedSession) {
                try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
        }
        #expect(session.randomDraws == 0)
    }

    private func neighbor(_ value: Double, offset: Int) -> Double {
        offset < 0 ? value.nextDown : (offset > 0 ? value.nextUp : value)
    }
}
