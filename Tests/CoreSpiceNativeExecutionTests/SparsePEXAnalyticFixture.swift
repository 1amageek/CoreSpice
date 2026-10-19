import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceIR
import Foundation

/// A Cartesian path graph has known cosine eigenvectors; G and C share them.
struct SparsePEXAnalyticFixture {
    let width: Int
    let height: Int
    var count: Int { width * height }
    var eigenvalue: Double {
        2 - 2 * cos(.pi / Double(width)) + (height > 1 ? 2 - 2 * cos(.pi / Double(height)) : 0)
    }
    var conductance: Double { 1e-3 * (1 + eigenvalue) }
    var capacitance: Double { 1e-9 * (1 + 0.25 * eigenvalue) }
    func mode(_ index: Int) -> Double {
        let x = cos(.pi * (Double(index % width) + 0.5) / Double(width))
        return height > 1 ? x * cos(.pi * (Double(index / width) + 0.5) / Double(height)) : x
    }
    func expectedAC(_ index: Int, frequency: Double) -> (real: Double, imag: Double) {
        let omegaC = 2 * Double.pi * frequency * capacitance
        let denominator = conductance * conductance + omegaC * omegaC
        return (mode(index) * 1e-3 * conductance / denominator,
                -mode(index) * 1e-3 * omegaC / denominator)
    }
    func expectedTransient(_ index: Int, time: Double) -> Double {
        let ramp = 1e-7, tau = capacitance / conductance
        let response = time <= ramp
            ? (time + tau * expm1(-time / tau)) / ramp
            : 1 - tau / ramp * (exp(-(time - ramp) / tau) - exp(-time / tau))
        return mode(index) * 1e-3 / conductance * response
    }
    func deck(_ analysis: String) -> String {
        var lines = ["Analytic coupled RC Laplacian eigenmode", ".options gmin=0 reltol=1e-7 vntol=1e-10"]
        for index in 0..<count {
            let source = -1e-3 * mode(index)
            lines += ["RG\(index) n\(index) 0 1000", "CG\(index) n\(index) 0 1e-9"]
            if analysis == "tran" {
                lines += ["I\(index) n\(index) 0 PWL(0 0 1e-7 \(source) 2e-6 \(source))", ".ic V(n\(index))=0"]
            } else {
                // An AC amplitude may be negative; its phase remains zero.
                lines += ["I\(index) n\(index) 0 DC \(source) AC \(source)"]
            }
            for next in [index % width + 1 < width ? index + 1 : nil,
                         index / width + 1 < height ? index + width : nil].compactMap({ $0 }) {
                lines += ["RE\(index)_\(next) n\(index) n\(next) 1000", "CE\(index)_\(next) n\(index) n\(next) 2.5e-10"]
            }
        }
        switch analysis {
        case "op": lines.append(".op")
        case "ac": lines.append(".ac lin 3 1000 1000000")
        case "tran": lines.append(".tran 1e-8 2e-6 0 1e-8 UIC")
        case "noise": lines.append(".noise V(n0) I0 lin 3 1000 1000000")
        default: preconditionFailure("Unknown analytic fixture analysis")
        }
        return (lines + [".end", ""]).joined(separator: "\n")
    }
    static func input(_ text: String, resources: SourceBoundaryTestResources,
                      maximumWorkUnits: Int = 100_000_000) async throws -> PreparedSPICESimulation {
        let bytes = Array(text.utf8)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "analytic-rc", reference: try ArtifactReference(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let source = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span, resources: resources, maximumPageByteCount: 4096)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "sparse-pex-test-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 4096)
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 20_000, maximumSolveAttempts: 40_000,
            maximumNewtonIterations: 100_000, maximumSavedScalars: 2_000_000, maximumMatrixDimension: 1024,
            maximumWorkUnits: maximumWorkUnits, maximumBreakpoints: 10_000)
        return try await SPICESimulationPreparer().prepare(.init(root: source, environment: environment,
            catalog: [binding], routes: [], provider: SparsePEXNoIncludes(), configuration: parser,
            operatingPolicy: .recordActual, limits: .init(maximumElements: 20_000,
                maximumTransformBytes: 128 * 1024 * 1024, maximumSweepPoints: 100,
                maximumPageByteCount: 4096, numerical: limits), profile: .coreStrictV1, seed: 1,
            resolutionLimits: .init(maximumRetainedBytes: 64 * 1024 * 1024, maximumDiagnosticBytes: 4096,
                maximumScopeDepth: 32, maximumSymbols: 20_000, maximumScopes: 32, maximumInvocations: 20_000,
                maximumInvocationBindings: 20_000, maximumDeclarations: 20_000, maximumPrograms: 20_000,
                maximumBindings: 20_000, maximumFunctions: 32, maximumFunctionDepth: 32,
                maximumExpressionNodes: 20_000, maximumExpressionDepth: 64, maximumCandidates: 20_000,
                maximumCacheEntries: 20_000, maximumEvaluationSteps: 100_000_000)), resources: resources)
    }
}

private struct SparsePEXNoIncludes: SPICEExactSourceProviding {
    func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
        throw SPICEExactSourceError.undeclaredSource(binding.key)
    }
}
