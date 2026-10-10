import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

/// Resolves separate model and instance scopes before preparing an analysis fixture.
enum PreparedMOSFixture {
    static func prepare(_ release: MOSModelRelease, polarity: MOSPolarity, name: String = "M1",
                        model: [String: Double], instance: [String: Double]) throws -> NativePreparedMOSDevice {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 8_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 256, maximumScopes: 16, maximumInvocations: 16,
            maximumInvocationBindings: 128, maximumDeclarations: 64, maximumPrograms: 256,
            maximumBindings: 256, maximumFunctions: 16, maximumFunctionDepth: 16,
            maximumExpressionNodes: 256, maximumExpressionDepth: 64, maximumCandidates: 64,
            maximumCacheEntries: 256, maximumEvaluationSteps: 100_000)
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let modelScope = try builder.addScope(parent: nil)
        let instanceScope = try builder.addScope(parent: modelScope)
        let reference = try builder.intern("fixture_model")
        var coefficients: [MOSExpressionBinding] = []
        for name in model.keys.sorted() {
            coefficients.append(try MOSExpressionBinding(symbol: builder.intern(name),
                program: builder.addProgram(.literal(model[name]!))))
        }
        let source = MOSSourceOccurrence(captureID: "devices-fixture", occurrenceID: 1,
            path: "devices-fixture.sp", line: 1, column: 1, statementByteOffset: 0, statementOrdinal: 0)
        _ = try builder.addModel(name: "fixture_model", scope: modelScope, polarity: polarity,
            level: release.level, version: release.exactVersion, coefficients: coefficients, source: source)
        var bindings: [MOSExpressionBinding] = []
        for name in instance.keys.sorted() {
            bindings.append(try MOSExpressionBinding(symbol: builder.intern(name),
                program: builder.addProgram(.literal(instance[name]!))))
        }
        let snapshot = try builder.finish()
        let modelInvocation = try MOSScopeInvocation(id: 1, scope: modelScope,
            callerInvocationID: nil, actuals: [], limits: limits)
        let instanceInvocation = try MOSScopeInvocation(id: 2, scope: instanceScope,
            callerInvocationID: 1, actuals: [], limits: limits)
        let graph = try MOSInvocationGraph(snapshot: snapshot,
            invocations: [modelInvocation, instanceInvocation], limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        let request = try MOSResolutionRequest(instance: name, scope: instanceScope, scopeInstantiation: 2,
            modelReference: reference, profile: .coreStrictV1, bindings: bindings,
            geometryScale: 1, seed: 1, limits: limits)
        let resolved = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        let conditions = try MOSPreparationConditions(ambientKelvin: 300.15, nominalKelvin: 300.15,
            analysisCapabilities: [.dc, .ac, .transient, .noise], maximumStressIterations: 1)
        let preparationLimits = try MOSPreparationLimits(maximumRetainedBytes: 8_000_000,
            maximumTemporaryBytes: 8_000_000, maximumDiagnosticBytes: 4096, maximumWorkUnits: 100_000)
        return try NativeMOSDevicePreparer().prepare(.init(resolved: resolved, conditions: conditions),
            limits: preparationLimits, control: DevicesMOSPreparationControl())
    }

    static func bind(typeName: String, name: String = "M1", nodes: [Node], model: [String: Double],
                     instance: [String: Double], variableMap: [MNAVariable: Int]) throws -> any BoundDevice {
        let release: MOSModelRelease
        switch typeName {
        case "nmos_l1", "pmos_l1": release = .level1
        case "nmos_l2", "pmos_l2": release = .level2
        case "nmos_l3", "pmos_l3": release = .level3
        default: throw MOSBindingFailure.identityMismatch
        }
        let owner = try prepare(release, polarity: typeName.hasPrefix("nmos") ? .nmos : .pmos,
            name: name, model: model, instance: instance)
        let preparedInstance = Instance(name: name, typeName: typeName, nodes: nodes,
            parameters: [:], mos: .prepared(owner.receipt))
        let dimension = variableMap.count
        var context = BindingContext(variableMap: variableMap, matrixDimension: dimension,
            stampIndexResolver: { $0 * dimension + $1 })
        return try owner.bind(instance: preparedInstance, context: &context)
    }
}

private struct DevicesMOSPreparationControl: MOSPreparationControlling {
    func checkCancellation() throws(MOSPreparationFailure) {
        if Task.isCancelled { throw .cancelled }
    }
    func chargeWork(units: UInt64) throws(MOSPreparationFailure) { try checkCancellation() }
}
