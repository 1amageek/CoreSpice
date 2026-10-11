import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParserSPICE
import Testing

@Suite("Pinned ordinary subcircuit multiplicity", .timeLimit(.minutes(1)))
struct HierarchicalMultiplierTests {
    private func lower(_ body: String, profile: MOSInputProfile = .pinnedNgspiceNormalV1) async throws -> LoweredCircuit {
        let parsed = try await SPICEParser().parse(source: "Multiplicity\n.model n nmos level=54 version=4.5\n\(body)\n.end\n").get()
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: profile, limits: limits, seed: 42)
        try session.lower()
        return try session.finish()
    }
    private func multipliers(_ result: LoweredCircuit) -> [Double?] {
        result.circuit.instances.compactMap { instance -> ResolvedMOSInstance? in
            if case .resolved(let value) = instance.mos { return value }; return nil
        }.map { value in value.instanceParameters.first { value.symbolNames[Int($0.symbol.rawValue)] == "m" }?.value }
    }
    @Test func explicitNestedActivationAndSiblingDefaultsDoNotLeak() async throws {
        let result = try await lower("""
        .subckt leaf d
        M1 d d 0 0 n l=1u w=1u
        .ends
        .subckt outer d
        Xinner d leaf m=2
        .ends
        Xfirst d outer m=3
        Xsecond d outer
        """)
        #expect(multipliers(result) == [3, 1])
    }
    @Test func explicitHeaderOwnsMultiplicityAndStrictProfileDoesNotInherit() async throws {
        let body = """
        .subckt leaf d m=1
        M1 d d 0 0 n l=1u w=1u m={m*2}
        .ends
        X1 d leaf m=3
        """
        #expect(multipliers(try await lower(body)) == [6])
        let implicit = """
        .subckt leaf d
        M1 d d 0 0 n l=1u w=1u
        .ends
        X1 d leaf m=3
        """
        #expect(multipliers(try await lower(implicit, profile: .coreStrictV1)) == [nil])
    }
    @Test func ordinaryModeAppendedMultiplierReplacesDeviceActualWithoutEvaluatingDiscardedRandom() async throws {
        let result = try await lower("""
        .subckt leaf d
        M1 d d 0 0 n l=1u w=1u m={rand()}
        .ends
        X1 d leaf m=4
        """)
        #expect(multipliers(result) == [4])
        #expect(result.evaluationProvenance.randomDraws == 0)
    }
    @Test func bodyMultiplierOwnsScalingAfterParameterPromotion() async throws {
        let result = try await lower("""
        .subckt leaf d
        .param m=5
        M1 d d 0 0 n l=1u w=1u
        .ends
        X1 d leaf
        X2 d leaf m=7
        """)
        #expect(multipliers(result) == [nil, nil])
    }
    @Test func sharedRandomMultiplierDrawsOnceAndResistorUsesSameBinding() async throws {
        let result = try await lower("""
        .subckt leaf d
        M1 d d 0 0 n l=1u w=1u
        M2 d d 0 0 n l=1u w=1u
        R1 d 0 1k
        V1 v 0 1
        .ends
        X1 d leaf m={1+rand()}
        """)
        let values = multipliers(result)
        #expect(values.count == 2 && values[0] == values[1])
        #expect(result.evaluationProvenance.randomDraws == 1)
        for instance in result.circuit.instances where instance.name.hasSuffix("r1") {
            guard case .real(let multiplier) = instance.parameters["m"] else { Issue.record("Missing inherited passive multiplier"); continue }
            #expect(multiplier == values[0])
        }
        #expect(result.circuit.instances.first { $0.name.hasSuffix("v1") }?.parameters["m"] == nil)
    }
    @Test(arguments: ["0", "-1", "1e308*1e308"])
    func invalidEffectiveMultiplierCannotPublishMOS(value: String) async throws {
        await #expect(throws: (any Error).self) {
            _ = try await lower("""
            .subckt leaf d
            M1 d d 0 0 n l=1u w=1u
            .ends
            X1 d leaf m={\(value)}
            """)
        }
    }

    @Test func unsupportedNonMOSMultiplicityIsRefusedBeforeDiscardedExpressionsRun() async throws {
        try await expectUnsupported("Hierarchical multiplicity for C is not implemented", body: """
            .subckt leaf d
            C1 d 0 {missing}
            .ends
            X1 d leaf m=3
            """)
    }

    @Test func implicitNestedRewriteIsRefusedAndUnusedCallCannotActivateUsedDeclaration() async throws {
        try await expectUnsupported("Implicit nested subcircuit multiplicity is outside pinned ordinary MOS scope", body: """
            .subckt leaf d
            M1 d d 0 0 n l=1u w=1u
            .ends
            .subckt outer d
            Xinner d leaf
            .ends
            X1 d outer m=3
            """)
        let result = try await lower("""
        .subckt leaf d
        M1 d d 0 0 n l=1u w=1u m=2
        .ends
        .subckt unused d
        Xunused d leaf m=3
        .ends
        X1 d leaf
        """)
        #expect(multipliers(result) == [2])
    }

    private func expectUnsupported(_ reason: String, body: String) async throws {
        do { _ = try await lower(body); Issue.record("Unsupported multiplier produced a circuit") }
        catch let error as LoweringError {
            guard case .unsupportedFeature(let feature) = error else { Issue.record("Unexpected lowering failure: \(error)"); return }
            #expect(feature == reason)
        }
    }

}
