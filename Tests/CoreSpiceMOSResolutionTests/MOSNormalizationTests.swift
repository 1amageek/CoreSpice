import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Classical MOS normalization")
struct MOSNormalizationTests {
    @Test func classicalScaleKeepsMultiplicityAndModelCoefficientsSeparate() throws {
        var f = try MOSSelectionFixture()
        let oxide = try f.binding("tox", 2e-9)
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
            version: nil, coefficients: [oxide], source: MOSSelectionFixture.source("n"))
        let values = try [f.binding("l", 1.5), f.binding("w", 3), f.binding("m", 3),
                          f.binding("ad", 4), f.binding("pd", 5)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(values, scale: 1e-6), from: snapshot,
            schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.rawGeometry.width == 3)
        #expect(result.normalizedGeometry.width == 3e-6)
        #expect(result.normalizedGeometry.drainArea == (4 * 1e-6) * 1e-6)
        #expect(result.instanceParameters.first { $0.symbol == snapshot.symbol(named: "m") }?.value == 3)
        #expect(result.modelCoefficients.first { $0.symbol == oxide.symbol }?.value == 2e-9)
    }

    @Test func classicExplicitAndDefaultOriginsRemainInspectable() throws {
        for (level, expected, origin) in [
            (nil, MOSModelRelease.level1, MOSReleaseOrigin.defaulted(.coreStrictV1)),
            (1, .level1, .explicitLevel(1)), (2, .level2, .explicitLevel(2)), (3, .level3, .explicitLevel(3))
        ] as [(Int?, MOSModelRelease, MOSReleaseOrigin)] {
            var f = try MOSSelectionFixture()
            _ = try f.model("n", level: level)
            let snapshot = try f.finish(), graph = try f.graph(snapshot)
            var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            let result = try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            #expect(result.release == expected && result.releaseOrigin == origin)
            #expect(try inspectResolvedMOS(result, from: snapshot, limits: f.limits).release == expected)
        }
    }

    @Test func nativeCompactModelsRequireOSDIWithoutProfileDefaults() throws {
        for profile in MOSInputProfile.allCases {
            for (level, version) in [(49, nil), (49, "3.3.0"), (54, nil),
                                      (54, "4.5"), (54, "4.8.3")] as [(Int, String?)] {
                var f = try MOSSelectionFixture()
                _ = try f.model("n", level: level, version: version)
                let snapshot = try f.finish(), graph = try f.graph(snapshot)
                var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
                let refusal = MOSResolutionFailure.osdiBindingRequired(level: level, version: version,
                    source: MOSSelectionFixture.source("n"))
                #expect(throws: refusal) {
                    try resolveMOS(f.request([], profile: profile), from: snapshot,
                        schemas: StandardMOSModelSchemas(), session: &session)
                }
                #expect(session.failureDiagnostic?.cause == refusal)
            }
        }
    }

    @Test func overflowAndPositiveToZeroScalingNeverPublishSuccess() throws {
        for (dimension, scale) in [(Double.greatestFiniteMagnitude, 2.0), (Double.leastNonzeroMagnitude, 0.5)] {
            var f = try MOSSelectionFixture()
            _ = try f.model("n")
            let values = try [f.binding("l", dimension)]
            let snapshot = try f.finish(), graph = try f.graph(snapshot)
            var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "scale"))) {
                try resolveMOS(f.request(values, scale: scale), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
        }
    }

    @Test func duplicateClassicalAssignmentsEvaluateThenPinnedKeepsLastValue() throws {
        var f = try MOSSelectionFixture()
        let rand = try f.builder.intern("rand"), vto = try f.builder.intern("vto")
        let random = try f.builder.addProgram(.function(rand, arguments: []))
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
            version: nil, coefficients: [.init(symbol: vto, program: random), .init(symbol: vto, program: random)],
            source: MOSSelectionFixture.source("n"))
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var strict = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.duplicateParameter(vto)) {
            try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &strict)
        }
        var pinned = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let request = try f.request([], profile: .pinnedNgspiceNormalV1)
        let result = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &pinned)
        #expect(pinned.randomDraws == 2 && result.modelCoefficients.count == 1)
        #expect(try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &pinned) == result)
        #expect(pinned.randomDraws == 2)
        #expect(throws: MOSResolutionFailure.invalidResolvedInstance) {
            try resolveMOS(request, from: snapshot, schemas: WrongMOSSchemaProvider(), session: &pinned)
        }
    }
}

private struct WrongMOSSchemaProvider: MOSModelSchemaProviding {
    func schema(for release: MOSModelRelease) throws(MOSSchemaFailure) -> MOSModelSchema { MOSModelSchema(release: .level2) }
}
