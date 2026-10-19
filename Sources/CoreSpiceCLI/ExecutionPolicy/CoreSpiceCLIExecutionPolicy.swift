import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts
import CircuiteFoundation

/// Explicit finite developer admission, independent of hardware or model qualification.
struct CoreSpiceCLIExecutionPolicy: Sendable {
    let profile: MOSInputProfile
    let diodeProfile: DiodeInputProfile
    let diodePreparationLimits: DiodePreparationLimits
    let seed: UInt64
    let resolutionLimits: MOSResolutionLimits
    let preparationLimits: MOSPreparationLimits
    let numericalLimits: TransientExecutionLimits
    let maximumElements: Int
    let maximumAllocationBytes: UInt64
    let maximumTemporaryBytes: UInt64
    let precisionBudget: CoreSpiceCLIPrecisionExecutionBudget?
    var executionProfile: CoreSpiceCLIExecutionProfile? = nil
    var executionProfileReference: ArtifactReference? = nil
    private var invocationResources: SPICESimulationResources? = nil
    var maximumSourceBytes: UInt64 { executionProfile?.maximumSourceBytes ?? 1024 * 1024 }

    static func developerV1(profile: MOSInputProfile = .pinnedNgspiceNormalV1,
                            seed: UInt64 = 1, diodeProfile: DiodeInputProfile = .genericDiodeV1) throws -> Self {
        // These ceilings select the existing prepared CLI invocation envelope.
        let elements = 8192
        return Self(profile: profile, diodeProfile: diodeProfile,
            diodePreparationLimits: try .init(maximumRetainedBytes: 64 * 1024, maximumTemporaryBytes: 4096, maximumWorkUnits: 1024), seed: seed,
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
            maximumTemporaryBytes: 64 * 1024 * 1024, precisionBudget: nil,
            invocationResources: try SPICESimulationResources(maximumLiveBytes: 128 * 1024 * 1024,
                maximumTemporaryBytes: 64 * 1024 * 1024, maximumWorkUnits: 1_000_000_000, maximumHashedBytes: 64 * 1024 * 1024))
    }

    func applying(_ budget: CoreSpiceCLIPrecisionExecutionBudget?) throws -> Self {
        guard let budget else { return self }
        guard executionProfile == nil else { throw CoreSpiceCLIExecutionProfile.Failure.conflictingPrecisionBudget }
        try budget.validate()
        return Self(profile: profile, diodeProfile: diodeProfile, diodePreparationLimits: diodePreparationLimits,
            seed: seed, resolutionLimits: resolutionLimits, preparationLimits: preparationLimits,
            numericalLimits: numericalLimits, maximumElements: maximumElements,
            maximumAllocationBytes: budget.maximumNativeAllocationBytes,
            maximumTemporaryBytes: budget.maximumTemporaryBytes, precisionBudget: budget,
            invocationResources: try SPICESimulationResources(maximumLiveBytes: budget.maximumLiveOwnedBytes,
                maximumTemporaryBytes: budget.maximumTemporaryBytes, maximumWorkUnits: 1_000_000_000, maximumHashedBytes: budget.maximumHashedBytes))
    }

    func resources() throws -> SPICESimulationResources {
        if let invocationResources { return invocationResources }
        return try SPICESimulationResources(maximumLiveBytes: precisionBudget?.maximumLiveOwnedBytes ?? 128 * 1024 * 1024,
            maximumTemporaryBytes: maximumTemporaryBytes,
            maximumWorkUnits: 1_000_000_000, maximumHashedBytes: precisionBudget?.maximumHashedBytes ?? 64 * 1024 * 1024)
    }

    func applying(_ selected: CoreSpiceCLIExecutionProfile, reference: ArtifactReference) throws -> Self {
        guard precisionBudget == nil, executionProfile == nil else {
            throw CoreSpiceCLIExecutionProfile.Failure.conflictingPrecisionBudget
        }
        try selected.validate()
        let elements = selected.maximumElements
        let resolution = try MOSResolutionLimits(maximumRetainedBytes: selected.maximumResolutionRetainedBytes,
            maximumDiagnosticBytes: resolutionLimits.maximumDiagnosticBytes,
            maximumScopeDepth: resolutionLimits.maximumScopeDepth, maximumSymbols: elements,
            maximumScopes: elements, maximumInvocations: elements, maximumInvocationBindings: elements,
            maximumDeclarations: elements, maximumPrograms: elements, maximumBindings: elements,
            maximumFunctions: elements, maximumFunctionDepth: resolutionLimits.maximumFunctionDepth,
            maximumExpressionNodes: elements, maximumExpressionDepth: resolutionLimits.maximumExpressionDepth,
            maximumCandidates: elements, maximumCacheEntries: elements,
            maximumEvaluationSteps: selected.maximumPreparationWorkUnits)
        var result = Self(profile: profile, diodeProfile: diodeProfile,
            diodePreparationLimits: diodePreparationLimits, seed: seed, resolutionLimits: resolution,
            preparationLimits: try MOSPreparationLimits(maximumRetainedBytes: preparationLimits.maximumRetainedBytes,
                maximumTemporaryBytes: preparationLimits.maximumTemporaryBytes,
                maximumDiagnosticBytes: preparationLimits.maximumDiagnosticBytes,
                maximumWorkUnits: selected.maximumPreparationWorkUnits), numericalLimits: numericalLimits,
            maximumElements: elements, maximumAllocationBytes: selected.maximumNativeAllocationBytes,
            maximumTemporaryBytes: selected.maximumTemporaryBytes, precisionBudget: nil)
        result.executionProfile = selected
        result.executionProfileReference = reference
        result.invocationResources = try SPICESimulationResources(maximumLiveBytes: selected.maximumLiveOwnedBytes,
            maximumTemporaryBytes: selected.maximumTemporaryBytes,
            maximumWorkUnits: selected.maximumPreparationWorkUnits, maximumHashedBytes: selected.maximumHashedBytes)
        try result.invocationResources?.chargeHashedBytes(reference.byteCount)
        return result
    }
}
