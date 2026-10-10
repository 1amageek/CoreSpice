import CoreSpice
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

/// Explicit source roles for analytical Level 1 numerical fixtures.
enum AnalysisMOSFixture {
    static func add(to netlist: inout Netlist, name: String, polarity: MOSPolarity,
                    nodes: [String], model: [String: Double], instance: [String: Double]) throws {
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 8_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 256, maximumScopes: 16, maximumInvocations: 16,
            maximumInvocationBindings: 128, maximumDeclarations: 64, maximumPrograms: 256,
            maximumBindings: 256, maximumFunctions: 16, maximumFunctionDepth: 16,
            maximumExpressionNodes: 256, maximumExpressionDepth: 64, maximumCandidates: 64,
            maximumCacheEntries: 256, maximumEvaluationSteps: 100_000)
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let scope = try builder.addScope(parent: nil)
        let reference = try builder.intern("analytical_model")
        var coefficients: [MOSExpressionBinding] = []
        for key in model.keys.sorted() {
            coefficients.append(try MOSExpressionBinding(symbol: builder.intern(key),
                program: builder.addProgram(.literal(model[key]!))))
        }
        let source = MOSSourceOccurrence(captureID: "analysis-" + name, occurrenceID: 1,
            path: "analysis-fixture.sp", line: 1, column: 1, statementByteOffset: 0, statementOrdinal: 0)
        _ = try builder.addModel(name: "analytical_model", scope: scope, polarity: polarity,
            level: 1, version: nil, coefficients: coefficients, source: source)
        var bindings: [MOSExpressionBinding] = []
        for key in instance.keys.sorted() {
            bindings.append(try MOSExpressionBinding(symbol: builder.intern(key),
                program: builder.addProgram(.literal(instance[key]!))))
        }
        let snapshot = try builder.finish()
        let invocation = try MOSScopeInvocation(id: 1, scope: scope, callerInvocationID: nil, actuals: [], limits: limits)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [invocation], limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        let request = try MOSResolutionRequest(instance: name, scope: scope, scopeInstantiation: 1,
            modelReference: reference, profile: .coreStrictV1, bindings: bindings, geometryScale: 1, seed: 1, limits: limits)
        let resolved = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        try netlist.addInstance(name: name, typeName: polarity == .nmos ? "nmos_l1" : "pmos_l1",
            nodes: nodes, mos: .resolved(resolved))
    }

    static func prepare(_ netlist: Netlist, numericalLimits: TransientExecutionLimits = .validationFixture)
        throws -> PreparedNativeCircuit {
        let conditions = OperatingConditions.nominal
        let resources = try SPICESimulationResources(maximumLiveBytes: 2 * 1024 * 1024 * 1024,
            maximumTemporaryBytes: 128 * 1024 * 1024, maximumWorkUnits: 1_000_000_000,
            maximumHashedBytes: 1_000_000)
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: 128, maximumMatrixDimension: 128,
            maximumAllocationBytes: 1024 * 1024 * 1024,
            mosPreparationLimits: try .init(maximumRetainedBytes: 1_000_000, maximumTemporaryBytes: 1_000_000,
                maximumDiagnosticBytes: 4096, maximumWorkUnits: 100_000),
            mosPreparationConditions: try .init(ambientKelvin: conditions.temperatureKelvin,
                nominalKelvin: conditions.nominalTemperatureKelvin, analysisCapabilities: [.dc, .ac, .transient],
                maximumStressIterations: 1))
        return try NativeCircuitPreparer().prepare(ir: netlist.build(), registry: .standard(),
            operatingConditions: conditions, limits: limits, numericalLimits: numericalLimits, resources: resources)
    }
}
