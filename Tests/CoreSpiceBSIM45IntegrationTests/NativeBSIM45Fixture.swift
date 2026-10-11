@testable import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceCompactModels
import CoreSpiceDevices
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParserSPICE
import Testing

/// These finite policies cover the fixture deck sizes, saved traces and oracle sweeps.
enum NativeBSIM45Fixture {
    static var numericalLimits: TransientExecutionLimits {
        .init(maximumAcceptedSteps: 250_000, maximumSolveAttempts: 1_000_000,
            maximumNewtonIterations: 5_000_000, maximumSavedScalars: 20_000_000,
            maximumMatrixDimension: 2_048, maximumWorkUnits: 1_000_000_000_000_000,
            maximumBreakpoints: 250_000)
    }
    static func resolutionLimits() throws -> MOSResolutionLimits {
        try .init(maximumRetainedBytes: 32_000_000, maximumDiagnosticBytes: 1_000_000,
            maximumScopeDepth: 32, maximumSymbols: 4096, maximumScopes: 256,
            maximumInvocations: 256, maximumInvocationBindings: 1024, maximumDeclarations: 1024,
            maximumPrograms: 8192, maximumBindings: 8192, maximumFunctions: 256,
            maximumFunctionDepth: 32, maximumExpressionNodes: 8192, maximumExpressionDepth: 128,
            maximumCandidates: 1024, maximumCacheEntries: 16384, maximumEvaluationSteps: 1_000_000)
    }
    static func frontend(_ source: String) async throws -> (LoweredCircuit, SPICEAnalysisOptions) {
        let parsed = try await SPICEParser().parse(source: source).get()
        let limits = try resolutionLimits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 1)
        let options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        try session.lower(geometryScale: options.geometryScale)
        return (try session.finish(), options)
    }
    static func prepare(_ source: String, temperature: Double = 300.15,
                        capabilities: MOSAnalysisCapabilities) async throws -> PreparedNativeCircuit {
        let (lowered, resolvedOptions) = try await frontend(source)
        var options = resolvedOptions
        if options.temperatureCelsius == nil { options.temperatureCelsius = temperature - 273.15 }
        options.bsim4NoisePreparationRequested = capabilities.contains(.noise)
        let operating = try options.operatingConditions()
        let conditions = try MOSPreparationConditions(ambientKelvin: operating.temperatureKelvin,
            nominalKelvin: operating.nominalTemperatureKelvin, analysisCapabilities: capabilities,
            maximumStressIterations: options.bsim4PreparationPolicy?.maximumStressIterations ?? 1)
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: 1024, maximumMatrixDimension: 2048,
            maximumAllocationBytes: 1_000_000_000,
            mosPreparationLimits: try .init(maximumRetainedBytes: 2_000_000,
                maximumTemporaryBytes: 2_000_000, maximumDiagnosticBytes: 1_000_000, maximumWorkUnits: 1_000_000),
            mosPreparationConditions: conditions)
        let resources = try SPICESimulationResources(maximumLiveBytes: 2_000_000_000,
            maximumTemporaryBytes: 2_000_000_000, maximumWorkUnits: 1_000_000_000_000_000,
            maximumHashedBytes: 32_000_000)
        return try NativeCircuitPreparer().prepare(ir: lowered.circuit, registry: options.deviceRegistry(),
            operatingConditions: operating, limits: limits, numericalLimits: numericalLimits, resources: resources)
    }
    static func mos(_ circuit: borrowing PreparedNativeCircuit) throws -> (instance: Instance, receipt: MOSPreparationReceipt) {
        let instance = try #require(circuit.plan.ir.instances.first { $0.name == "m1" })
        guard case .prepared(let receipt) = instance.mos else { throw MOSBindingFailure.missingPreparedReceipt }
        return (instance, receipt)
    }
}
