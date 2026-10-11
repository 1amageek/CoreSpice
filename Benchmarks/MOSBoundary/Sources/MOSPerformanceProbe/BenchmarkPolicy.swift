import CoreSpice
import CoreSpiceIO
import CoreSpiceMOSContracts

struct BenchmarkPolicy {
    let profile: MOSInputProfile = .pinnedNgspiceNormalV1
    let seed: UInt64 = 92
    let resolution: MOSResolutionLimits
    let native: SPICENativeExecutionLimits
    let numerical: TransientExecutionLimits
    init() throws {
        resolution = try .init(maximumRetainedBytes: 16 * 1024 * 1024, maximumDiagnosticBytes: 1024 * 1024,
            maximumScopeDepth: 64, maximumSymbols: 8192, maximumScopes: 8192, maximumInvocations: 8192,
            maximumInvocationBindings: 8192, maximumDeclarations: 8192, maximumPrograms: 8192,
            maximumBindings: 8192, maximumFunctions: 8192, maximumFunctionDepth: 64,
            maximumExpressionNodes: 8192, maximumExpressionDepth: 64, maximumCandidates: 8192,
            maximumCacheEntries: 8192, maximumEvaluationSteps: 1_000_000_000)
        numerical = .init(maximumAcceptedSteps: 1000, maximumSolveAttempts: 2000,
            maximumNewtonIterations: 10000, maximumSavedScalars: 4096, maximumMatrixDimension: 128,
            maximumWorkUnits: 100_000_000, maximumBreakpoints: 1000)
        native = .init(maximumDeviceCount: 128, maximumMatrixDimension: 128,
            maximumAllocationBytes: 32 * 1024 * 1024,
            mosPreparationLimits: try .init(maximumRetainedBytes: 1024 * 1024,
                maximumTemporaryBytes: 1024 * 1024, maximumDiagnosticBytes: 4096, maximumWorkUnits: 1_000_000),
            mosPreparationConditions: try .init(ambientKelvin: 300.15, nominalKelvin: 300.15,
                analysisCapabilities: [.dc], maximumStressIterations: 128))
    }
    func source(release: String) throws -> String {
        let selector: String, parameters: String
        switch release {
        case "level1": selector = "level=1"; parameters = "vto={0.4+delta} kp=1e-4"
        case "bsim3": selector = "level=49 version=3.3.0"; parameters = "tox=1e-8 vth0={0.4+delta} u0=0.05"
        case "bsim45": selector = "level=54 version=4.5"; parameters = "toxe=1e-8 vth0={0.4+delta} u0=0.05"
        case "bsim4": selector = "level=54 version=4.8.3"; parameters = "toxe=1e-8 vth0={0.4+delta} u0=0.05"
        default: throw BenchmarkFailure.invalidArguments
        }
        var source = "CPU MOS performance\n.param delta={rand()*0.01}\nVDD d 0 1\nVG g 0 1\nRload d 0 1k\n"
        if release == "level1" {
            source += ".model nm NMOS \(selector) \(parameters)\n"
        } else {
            source += ".model nm.1 NMOS \(selector) \(parameters) lmin=0 lmax=2u wmin=0 wmax=20u\n"
            source += ".model nm.2 NMOS \(selector) \(parameters) lmin=2u lmax=20u wmin=0 wmax=20u\n"
        }
        for index in 0..<8 { source += "M\(index) d g 0 0 nm l=1u w=10u\n" }
        return source + ".options bsim4stressiterations=128\n.dc VG 0 1 0.25\n.end\n"
    }
}

enum BenchmarkFailure: Error { case invalidArguments, missingScalar, invalidResult, downstreamResolutionChanged, preparationChanged }
