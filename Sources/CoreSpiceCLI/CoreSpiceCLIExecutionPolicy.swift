import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceMOSContracts

/// Explicit finite developer admission, independent of hardware or model qualification.
struct CoreSpiceCLIExecutionPolicy: Sendable {
    let profile: MOSInputProfile
    let seed: UInt64
    let resolutionLimits: MOSResolutionLimits
    let preparationLimits: MOSPreparationLimits
    let numericalLimits: TransientExecutionLimits
    let maximumElements: Int
    let maximumAllocationBytes: UInt64
    let maximumTemporaryBytes: UInt64

    static func developerV1(profile: MOSInputProfile = .pinnedNgspiceNormalV1,
                            seed: UInt64 = 1) throws -> Self {
        // These ceilings select the existing prepared CLI invocation envelope.
        let elements = 8192
        return Self(profile: profile, seed: seed,
            resolutionLimits: try MOSResolutionLimits(maximumRetainedBytes: 16 * 1024 * 1024,
                maximumDiagnosticBytes: 1024 * 1024, maximumScopeDepth: 64,
                maximumSymbols: elements, maximumScopes: elements, maximumInvocations: elements,
                maximumInvocationBindings: elements, maximumDeclarations: elements,
                maximumPrograms: elements, maximumBindings: elements, maximumFunctions: elements,
                maximumFunctionDepth: 64, maximumExpressionNodes: elements,
                maximumExpressionDepth: 64, maximumCandidates: elements,
                maximumCacheEntries: elements, maximumEvaluationSteps: 1_000_000_000),
            preparationLimits: try MOSPreparationLimits(maximumRetainedBytes: 1024 * 1024,
                maximumTemporaryBytes: 1024 * 1024, maximumDiagnosticBytes: 64 * 1024,
                maximumWorkUnits: 1_000_000_000),
            numericalLimits: TransientExecutionLimits(maximumAcceptedSteps: 100_000,
                maximumSolveAttempts: 200_000, maximumNewtonIterations: 1_000_000,
                maximumSavedScalars: 1_000_000, maximumMatrixDimension: 256,
                maximumWorkUnits: 1_000_000_000, maximumBreakpoints: 100_000),
            maximumElements: elements, maximumAllocationBytes: 64 * 1024 * 1024,
            maximumTemporaryBytes: 64 * 1024 * 1024)
    }

    func resources() throws -> SPICESimulationResources {
        try SPICESimulationResources(maximumLiveBytes: 128 * 1024 * 1024,
            maximumTemporaryBytes: maximumTemporaryBytes,
            maximumWorkUnits: 1_000_000_000, maximumHashedBytes: 64 * 1024 * 1024)
    }
}
