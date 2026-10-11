import CoreSpiceMOSContracts
import Testing
@testable import CoreSpiceCompile
@testable import CoreSpiceIR

@Suite("Prepared MOS compiler admission")
struct MOSStageAdmissionTests {
    private let ports = [Node(id: 1), Node(id: 2), Node(id: 3), Node.ground]

    @Test func legacyDictionariesCannotAdmitMOSAndResolvedStageIsRefused() throws {
        let legacy = Instance(name: "M1", typeName: "nmos", nodes: ports,
            parameters: ["w": .real(1e-6), "l": .real(1e-6), "kp": .real(1e-3)])
        #expect(throws: CompileError.mosPreparationRequired(instance: "M1")) {
            try StandardCompiler().compile(ir: circuit(legacy))
        }
        let resolved = try resolution()
        let staged = Instance(name: "M1", typeName: "nmos", nodes: ports,
            parameters: [:], mos: .resolved(resolved))
        #expect(throws: CompileError.mosNotPrepared(instance: "M1")) {
            try StandardCompiler().compile(ir: circuit(staged))
        }
    }

    @Test func preparedClassicAndNativeReleasesCompileUsingReceiptAuthority() throws {
        for release in [MOSModelRelease.level1, .level2, .level3, .bsim3_3_3_0, .bsim4_4_8_3] {
            for polarity in [MOSPolarity.nmos, .pmos] {
                let receipt = try receipt(resolution(release: release, polarity: polarity))
                let prefix = polarity == .nmos ? "nmos" : "pmos"
                let typeName = release == .level1 ? prefix : "\(prefix)_l\(release.level)"
                let instance = Instance(name: "M1", typeName: typeName, nodes: ports,
                    parameters: ["w": .real(-1), "level": .integer(999)], mos: .prepared(receipt))
                let plan = try StandardCompiler().compile(ir: circuit(instance))
                #expect(plan.deviceNames == ["M1"])
                #expect(plan.topology.nodeIndex(ports[0]) != nil)
                #expect(plan.ir.instances[0].mos == .prepared(receipt))
            }
        }
    }

    @Test func preparedReceiptMustMatchTypePolarityAndInstanceIdentity() throws {
        let classic = try receipt(resolution())
        #expect(throws: CompileError.mosReleaseMismatch(instance: "M1", expectedLevel: 54, actual: .level1)) {
            try StandardCompiler().compile(ir: circuit(Instance(name: "M1", typeName: "nmos_l54", nodes: ports,
                parameters: [:], mos: .prepared(classic))))
        }
        #expect(throws: CompileError.mosPolarityMismatch(instance: "M1", expected: .pmos, actual: .nmos)) {
            try StandardCompiler().compile(ir: circuit(Instance(name: "M1", typeName: "pmos", nodes: ports,
                parameters: [:], mos: .prepared(classic))))
        }
        #expect(throws: CompileError.mosInstanceMismatch(instance: "M2", receipt: "M1")) {
            try StandardCompiler().compile(ir: circuit(Instance(name: "M2", typeName: "nmos", nodes: ports,
                parameters: [:], mos: .prepared(classic))))
        }
        #expect(throws: CompileError.unexpectedMOSStage(instance: "M1")) {
            try StandardCompiler().compile(ir: circuit(Instance(name: "M1", typeName: "resistor", nodes: ports,
                parameters: [:], mos: .prepared(classic))))
        }
        let unsupported = try receipt(resolution(release: .bsim4_4_5))
        // A custom prepared receipt is topology authority; native numerical
        // capability is tested at NativeMOSDevicePreparer, not in the compiler.
        _ = try StandardCompiler().compile(ir: circuit(Instance(name: "M1", typeName: "nmos_l54", nodes: ports,
            parameters: [:], mos: .prepared(unsupported))))
    }

    @Test func privateTopologyIsRetainedAndEveryRequiredSparsePairExists() throws {
        let receipt = try receipt(resolution(release: .bsim3_3_3_0), auxiliary: true)
        let privateNode = Node(id: 5)
        let instance = Instance(name: "M1", typeName: "nmos_l49", nodes: ports,
            parameters: [:], mos: .prepared(receipt), ownedNodes: [privateNode])
        let plan = try StandardCompiler().compile(ir: circuit(instance, extraNodes: [privateNode]))
        let privateIndex = try #require(plan.topology.nodeIndex(privateNode))
        let gateIndex = try #require(plan.topology.nodeIndex(ports[1]))
        #expect(privateIndex != gateIndex)
        #expect(plan.matrixStructure.index(row: privateIndex, col: gateIndex) != nil)
        #expect(plan.matrixStructure.index(row: gateIndex, col: privateIndex) != nil)
    }

    @Test func malformedPortsAuxiliaryCountAndAbsentNodesRefuseCompilation() throws {
        let classic = try receipt(resolution())
        #expect(throws: CompileError.mosPhysicalPortCount(instance: "M1", actual: 3)) {
            try StandardCompiler().compile(ir: circuit(Instance(name: "M1", typeName: "nmos", nodes: Array(ports.prefix(3)),
                parameters: [:], mos: .prepared(classic))))
        }
        let auxiliary = try receipt(resolution(release: .bsim3_3_3_0), auxiliary: true)
        #expect(throws: CompileError.mosAuxiliaryNodeCount(instance: "M1", expected: 1, actual: 0)) {
            try StandardCompiler().compile(ir: circuit(Instance(name: "M1", typeName: "nmos_l49", nodes: ports,
                parameters: [:], mos: .prepared(auxiliary))))
        }
        let missingPort = Instance(name: "M1", typeName: "nmos", nodes: [ports[0], ports[1], Node(id: 77), .ground],
            parameters: [:], mos: .prepared(classic))
        #expect(throws: CompileError.mosNodeMissing(instance: "M1", node: 77)) {
            try StandardCompiler().compile(ir: circuit(missingPort))
        }
        let missingPrivate = Instance(name: "M1", typeName: "nmos_l49", nodes: ports,
            parameters: [:], mos: .prepared(auxiliary), ownedNodes: [Node(id: 88)])
        #expect(throws: CompileError.mosNodeMissing(instance: "M1", node: 88)) {
            try StandardCompiler().compile(ir: circuit(missingPrivate))
        }
    }

    @Test func privateNodesCannotAliasAnyPhysicalPortOrAnotherOwner() throws {
        let receipt = try receipt(resolution(release: .bsim3_3_3_0), auxiliary: true)
        let ownAlias = Instance(name: "M1", typeName: "nmos_l49", nodes: ports,
            parameters: [:], mos: .prepared(receipt), ownedNodes: [ports[0]])
        #expect(throws: CompileError.mosPrivateNodeAlias(instance: "M1", node: ports[0].id)) {
            try StandardCompiler().compile(ir: circuit(ownAlias))
        }
        let privateNode = Node(id: 5)
        let mos = Instance(name: "M1", typeName: "nmos_l49", nodes: ports,
            parameters: [:], mos: .prepared(receipt), ownedNodes: [privateNode])
        for other in [
            Instance(name: "R1", typeName: "resistor", nodes: [privateNode, .ground], parameters: [:]),
            Instance(name: "X1", typeName: "other", nodes: [], parameters: [:], ownedNodes: [privateNode])
        ] {
            for instances in [[mos, other], [other, mos]] {
                #expect(throws: CompileError.mosPrivateNodeAlias(instance: "M1", node: 5)) {
                    try StandardCompiler().compile(ir: CircuitIR(nodes: ports + [privateNode], branches: [], instances: instances))
                }
            }
        }
    }

    @Test func nonMOSCompilationRetainsExistingPath() throws {
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [ports[0], .ground], parameters: ["r": .real(1000)])
        let plan = try StandardCompiler().compile(ir: circuit(instance))
        #expect(plan.deviceNames == ["R1"] && plan.topology.dimension == 3)
    }

    private func circuit(_ instance: Instance, extraNodes: [Node] = []) -> CircuitIR {
        CircuitIR(nodes: ports + extraNodes, branches: [], instances: [instance])
    }

    private func resolution(release: MOSModelRelease = .level1, polarity: MOSPolarity = .nmos) throws -> ResolvedMOSInstance {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 100_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 8, maximumSymbols: 16, maximumScopes: 8, maximumInvocations: 8,
            maximumInvocationBindings: 16, maximumDeclarations: 8, maximumPrograms: 16, maximumBindings: 16,
            maximumFunctions: 8, maximumFunctionDepth: 8, maximumExpressionNodes: 16, maximumExpressionDepth: 16,
            maximumCandidates: 8, maximumCacheEntries: 16, maximumEvaluationSteps: 100_000)
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes, maximumSteps: limits.maximumEvaluationSteps)
        let source = MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: "compiler-fixture.sp",
            line: 1, column: 1, statementByteOffset: nil, statementOrdinal: nil)
        return try ResolvedMOSInstance(identitySpace: MOSIdentitySpace(), source: source, instanceSource: source,
            selectedName: .init(0), symbolNames: ["n", "l", "w"], scope: .init(0), scopeInstantiation: 1,
            instance: "M1", declaration: .init(0), polarity: polarity, release: release,
            releaseOrigin: release.exactVersion.map(MOSReleaseOrigin.explicit) ?? .explicitLevel(release.level),
            schema: release.schemaIdentity, modelCoefficients: [],
            instanceParameters: [.init(symbol: .init(1), value: 1e-6), .init(symbol: .init(2), value: 1e-6)],
            rawGeometry: .init(length: 1e-6, width: 1e-6), normalizedGeometry: .init(length: 1e-6, width: 1e-6),
            selectionGeometry: .init(length: 1e-6, width: 1e-6, fingerDivisor: 1), profile: .coreStrictV1,
            geometryScale: 1, rules: [.nearestScope, .exactName, .strictUnique, .strictBounds, .suppliedGeometryOnly,
                .fullDeviceWidth, .unscaledModelCoefficients], candidates: [.init(declaration: .init(0), disposition: .selected)],
            limits: limits, workBudget: &budget)
    }

    private func receipt(_ resolved: ResolvedMOSInstance, auxiliary: Bool = false) throws -> MOSPreparationReceipt {
        let conditions = try MOSPreparationConditions(ambientKelvin: 300.15, nominalKelvin: 300.15,
            analysisCapabilities: [.dc], maximumStressIterations: 1)
        let identity = try MOSPreparationIdentity(resolved: resolved, conditions: conditions, implementationIdentity: "compiler-test-fixture-v1")
        let topology = try MOSPreparedTopology(localNodeCount: auxiliary ? 5 : 4, drainPrime: auxiliary ? 5 : 1,
            sourcePrime: 3, gatePrime: 2, gateMid: 2, bodyPrime: 4, drainBody: 4, sourceBody: 4, chargeNode: 0)
        let limits = try MOSPreparationLimits(maximumRetainedBytes: 100_000, maximumTemporaryBytes: 100_000,
            maximumDiagnosticBytes: 4096, maximumWorkUnits: 100_000)
        // The package-only fixture admits compiler metadata; it does not claim device preparation evidence.
        return try MOSPreparationReceipt(identity: identity, topology: topology, retainedBytes: 4096,
            peakTemporaryBytes: 0, coldSetupCount: 1, limits: limits)
    }
}
