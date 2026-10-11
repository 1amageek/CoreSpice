import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Release-specific MOS normalization")
struct MOSNormalizationTests {
    @Test func scaleUsesParameterRolesAndKeepsMultiplicitySeparateFromRealFingers() throws {
        var f = try MOSSelectionFixture()
        let binunit = try f.binding("binunit", 1), oxide = try f.binding("toxe", 2e-9)
        let model = try f.bin("n.1", bounds: [1e-6, 2e-6, 1e-6, 2e-6], extras: [binunit, oxide])
        let values = try [f.binding("l", 1.5), f.binding("w", 3), f.binding("nf", 2.5),
            f.binding("m", 3), f.binding("ad", 4), f.binding("pd", 5), f.binding("sa", 6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var strict = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.noMatchingBin(f.model)) {
            try resolveMOS(f.request(values, scale: 1e-6), from: snapshot, schemas: StandardMOSModelSchemas(), session: &strict)
        }
        var pinned = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(values, profile: .pinnedNgspiceNormalV1, scale: 1e-6, fingers: true),
            from: snapshot, schemas: StandardMOSModelSchemas(), session: &pinned)
        #expect(result.declaration == model && result.rawGeometry.width == 3)
        #expect(result.normalizedGeometry.width == 3e-6)
        #expect(result.selectionGeometry.width == (3 / 2.5) * 1e-6)
        #expect(result.selectionGeometry.fingerDivisor == 2.5)
        #expect(result.normalizedGeometry.drainArea == (4 * 1e-6) * 1e-6)
        #expect(result.instanceParameters.first { $0.symbol == nfSymbol(snapshot) }?.value == 2.5)
        #expect(result.instanceParameters.first { $0.symbol == snapshot.symbol(named: "m") }?.value == 3)
        #expect(result.instanceParameters.first { $0.symbol == snapshot.symbol(named: "sa") }?.value == 6e-6)
        #expect(result.modelCoefficients.first { $0.symbol == oxide.symbol }?.value == 2e-9)
        #expect(result.modelCoefficients.first { $0.symbol == binunit.symbol }?.value == 1)
    }

    @Test func classicExplicitAndDefaultOriginsAndExactNonExecutable45AreInspectable() throws {
        for (level, version, expected, origin) in [
            (nil, nil, MOSModelRelease.level1, MOSReleaseOrigin.defaulted(.coreStrictV1)),
            (2, nil, .level2, .explicitLevel(2)), (54, "4.5", .bsim4_4_5, .explicit("4.5"))
        ] as [(Int?, String?, MOSModelRelease, MOSReleaseOrigin)] {
            var f = try MOSSelectionFixture()
            _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: level,
                version: version, coefficients: [], source: MOSSelectionFixture.source("n"))
            let snapshot = try f.finish(), graph = try f.graph(snapshot)
            var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            let result = try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            #expect(result.release == expected && result.releaseOrigin == origin)
            #expect(try inspectResolvedMOS(result, from: snapshot, limits: f.limits).release == expected)
        }
    }

    @Test func strictMissingBSIMVersionRefusesAndPinnedRetainsExactDefaultOrigin() throws {
        for level in [49, 54] {
            var f = try MOSSelectionFixture()
            _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: level,
                version: nil, coefficients: [], source: MOSSelectionFixture.source("n"))
            let snapshot = try f.finish(), graph = try f.graph(snapshot)
            var strict = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            #expect(throws: MOSResolutionFailure.schema(.unsupportedRelease(level: level, version: nil))) {
                try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &strict)
            }
            var pinned = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            let result = try resolveMOS(f.request([], profile: .pinnedNgspiceNormalV1), from: snapshot,
                schemas: StandardMOSModelSchemas(), session: &pinned)
            #expect(result.release == (level == 49 ? .bsim3_3_3_0 : .bsim4_4_8_3))
            #expect(result.releaseOrigin == .defaulted(.pinnedNgspiceNormalV1))
        }
    }

    @Test func exact45SpellingsPreserveOriginAndScaleSCOnlyOnce() throws {
        for (version, profile) in [("4.5", MOSInputProfile.coreStrictV1), ("4.5.0", .coreStrictV1), ("4.500000e+0", .pinnedNgspiceNormalV1)] {
            var f = try MOSSelectionFixture()
            _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 54,
                version: version, coefficients: [], source: MOSSelectionFixture.source("n"))
            let values = try [f.binding("sc", 2), f.binding("sca", 3), f.binding("nf", 1.5)]
            let snapshot = try f.finish(), graph = try f.graph(snapshot)
            var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            let result = try resolveMOS(f.request(values, profile: profile, scale: 1e-6), from: snapshot,
                schemas: StandardMOSModelSchemas(), session: &session)
            #expect(result.release == .bsim4_4_5 && result.releaseOrigin == .explicit(version))
            #expect(result.instanceParameters.first { $0.symbol == snapshot.symbol(named: "sc") }?.value == 2e-6)
            #expect(result.instanceParameters.first { $0.symbol == snapshot.symbol(named: "sca") }?.value == 3)
            #expect(result.normalizedGeometry.length == nil && result.normalizedGeometry.width == nil)
        }
    }

    @Test func overflowAndPositiveToZeroScalingNeverPublishSuccess() throws {
        for (dimension, scale) in [(Double.greatestFiniteMagnitude, 2.0), (Double.leastNonzeroMagnitude, 0.5)] {
            var f = try MOSSelectionFixture()
            _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
                version: nil, coefficients: [], source: MOSSelectionFixture.source("n"))
            let values = try [f.binding("l", dimension)]
            let snapshot = try f.finish(), graph = try f.graph(snapshot)
            var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
            #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "scale"))) {
                try resolveMOS(f.request(values, scale: scale), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
            }
        }
    }

    @Test func sourceOrderAliasesEvaluateThenPinnedKeepsWinningRawSymbol() throws {
        var f = try MOSSelectionFixture()
        let rand = try f.builder.intern("rand")
        let random = try f.builder.addProgram(.function(rand, arguments: []))
        let canonical = try f.builder.intern("vth0"), alias = try f.builder.intern("vtho")
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 54,
            version: "4.8.3", coefficients: [MOSExpressionBinding(symbol: canonical, program: random),
                MOSExpressionBinding(symbol: alias, program: random)], source: MOSSelectionFixture.source("n"))
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var strict = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.duplicateParameter(alias)) {
            try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &strict)
        }
        var pinned = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let request = try f.request([], profile: .pinnedNgspiceNormalV1)
        let result = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &pinned)
        #expect(pinned.randomDraws == 2)
        #expect(result.modelCoefficients.count == 1 && result.modelCoefficients[0].symbol == alias)
        let again = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &pinned)
        #expect(again == result && pinned.randomDraws == 2)
        #expect(throws: MOSResolutionFailure.invalidResolvedInstance) {
            try resolveMOS(request, from: snapshot, schemas: WrongMOSSchemaProvider(), session: &pinned)
        }
        #expect(pinned.randomDraws == 2)
    }

    private func nfSymbol(_ snapshot: MOSDeclarationSnapshot) -> MOSSymbolID? { snapshot.symbol(named: "nf") }
}

private struct WrongMOSSchemaProvider: MOSModelSchemaProviding {
    func schema(for release: MOSModelRelease) throws(MOSSchemaFailure) -> MOSModelSchema { MOSModelSchema(release: .level1) }
}
