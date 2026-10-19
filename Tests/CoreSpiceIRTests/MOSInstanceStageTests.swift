import CoreSpiceMOSContracts
import Testing
@testable import CoreSpiceIR

@Suite("Canonical immutable MOS stages")
struct MOSInstanceStageTests {
    @Test func nonMOSInstancesHaveNoImplicitMOSStage() {
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [.ground], parameters: [:])
        #expect(instance.mos == nil)
    }

    @Test func resolvedAndPreparedStagesRetainExactValuesAcrossNetlistBuild() throws {
        let resolved = try resolution()
        let conditions = try MOSPreparationConditions(ambientKelvin: 300.15, nominalKelvin: 300.15,
            analysisCapabilities: [.dc, .ac])
        let identity = try MOSPreparationIdentity(resolved: resolved, conditions: conditions, implementationIdentity: "ir-test-fixture-v1")
        let topology = MOSPreparedTopology()
        let limits = try MOSPreparationLimits(maximumRetainedBytes: 100_000, maximumTemporaryBytes: 100_000,
            maximumDiagnosticBytes: 4096, maximumWorkUnits: 100_000)
        let receipt = try MOSPreparationReceipt(identity: identity, topology: topology, retainedBytes: 4096,
            peakTemporaryBytes: 0, coldSetupCount: 1, limits: limits)
        for stage in [MOSInstanceStage.resolved(resolved), .prepared(receipt)] {
            var netlist = Netlist()
            try netlist.addInstance(name: "M1", typeName: "nmos", nodes: ["d", "g", "s", "0"],
                parameters: ["w": .real(-9)], mos: stage)
            let circuit = try netlist.build()
            let instance = try #require(circuit.instances.first)
            #expect(instance.mos == stage)
            if case .real(let value)? = instance.parameters["w"] { #expect(value == -9) }
            else { Issue.record("Netlist build changed the separate legacy parameter dictionary") }
            switch instance.mos {
            case .resolved(let value): #expect(value == resolved)
            case .prepared(let value): #expect(value.identity.resolved == resolved && value.topology == topology)
            case nil: Issue.record("Netlist build lost the MOS stage")
            }
        }
    }

    private func resolution() throws -> ResolvedMOSInstance {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 100_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 8, maximumSymbols: 16, maximumScopes: 8, maximumInvocations: 8,
            maximumInvocationBindings: 16, maximumDeclarations: 8, maximumPrograms: 16, maximumBindings: 16,
            maximumFunctions: 8, maximumFunctionDepth: 8, maximumExpressionNodes: 16, maximumExpressionDepth: 16,
            maximumCandidates: 8, maximumCacheEntries: 16, maximumEvaluationSteps: 100_000)
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes, maximumSteps: limits.maximumEvaluationSteps)
        let source = MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: "ir-fixture.sp",
            line: 1, column: 1, statementByteOffset: nil, statementOrdinal: nil)
        return try ResolvedMOSInstance(identitySpace: MOSIdentitySpace(), source: source, instanceSource: source,
            selectedName: .init(0), symbolNames: ["n", "l", "w"], scope: .init(0), scopeInstantiation: 1,
            instance: "M1", declaration: .init(0), polarity: .nmos, release: .level1,
            releaseOrigin: .explicitLevel(1), schema: MOSModelRelease.level1.schemaIdentity, modelCoefficients: [],
            instanceParameters: [.init(symbol: .init(1), value: 1e-6), .init(symbol: .init(2), value: 1e-6)],
            rawGeometry: .init(length: 1e-6, width: 1e-6), normalizedGeometry: .init(length: 1e-6, width: 1e-6),
            selectionGeometry: .init(length: 1e-6, width: 1e-6, fingerDivisor: 1), profile: .coreStrictV1,
            geometryScale: 1, rules: [.nearestScope, .exactName, .strictUnique, .strictBounds, .suppliedGeometryOnly,
                .fullDeviceWidth, .unscaledModelCoefficients], candidates: [.init(declaration: .init(0), disposition: .selected)],
            limits: limits, workBudget: &budget)
    }
}
