import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceWaveform
import Foundation

@main
struct SparseQualificationTool {
    enum Failure: Error { case arguments, missingValue(String), roundtripMismatch(String), unexpectedInclude(String), sourceOverridesWorkLimit }
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--matrix" { try SparseMatrixQualification.run(arguments); return }
        guard arguments.count == 5 || arguments.count == 7, let bytesLimit = UInt64(arguments[3]), bytesLimit > 0,
              let workLimit = Int(arguments[4]), workLimit > 0 else { throw Failure.arguments }
        let liveBytes: UInt64
        if arguments.count == 7 {
            guard arguments[5] == "--live-bytes", let value = UInt64(arguments[6]), value > 0 else { throw Failure.arguments }
            liveBytes = value
        } else { liveBytes = bytesLimit }
        // Arguments: deck, CSV, JSON, admitted bytes, numerical work units, optional live-owned bytes.
        let started = ProcessInfo.processInfo.systemUptime
        let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let resources = try SPICESimulationResources(maximumLiveBytes: liveBytes,
            maximumTemporaryBytes: bytesLimit, maximumWorkUnits: UInt64(workLimit), maximumHashedBytes: bytesLimit)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(bytes.count), maximumTotalByteCount: UInt64(bytes.count), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
        }
        let binding = SPICEExactSourceBinding(key: "root", reference: try ArtifactReference(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let source = try SPICECheckedSource.admit(binding: binding, bytes: bytes.span,
            resources: resources, maximumPageByteCount: 4096)
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "sparse-qualification-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 4096)
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 10_000, maximumSolveAttempts: 40_000,
            maximumNewtonIterations: 100_000, maximumSavedScalars: 10_000_000, maximumMatrixDimension: 250_000,
            maximumWorkUnits: workLimit, maximumBreakpoints: 100_000)
        let elements = 100_000
        let input = try await SPICESimulationPreparer().prepare(.init(root: source, environment: environment,
            catalog: [binding], routes: [], provider: NoIncludes(), configuration: parser,
            operatingPolicy: .recordActual, limits: .init(maximumElements: elements,
                maximumTransformBytes: bytesLimit, maximumSweepPoints: 1000,
                maximumPageByteCount: 4096, numerical: limits), profile: .coreStrictV1, seed: 1,
            resolutionLimits: MOSResolutionLimits(maximumRetainedBytes: bytesLimit / 8,
                maximumDiagnosticBytes: 1024 * 1024, maximumScopeDepth: 64,
                maximumSymbols: elements, maximumScopes: elements, maximumInvocations: elements,
                maximumInvocationBindings: elements, maximumDeclarations: elements,
                maximumPrograms: elements, maximumBindings: elements, maximumFunctions: elements,
                maximumFunctionDepth: 64, maximumExpressionNodes: elements, maximumExpressionDepth: 64,
                maximumCandidates: elements, maximumCacheEntries: elements,
                maximumEvaluationSteps: UInt64(workLimit))), resources: resources)
        guard input.configuration.numericalLimits.maximumWorkUnits <= workLimit else { throw Failure.sourceOverridesWorkLimit }
        let frontendFinished = ProcessInfo.processInfo.systemUptime
        let prepared = try SPICENativeSimulation().prepare(input, limits: .init(maximumDeviceCount: elements,
            maximumMatrixDimension: input.configuration.numericalLimits.maximumMatrixDimension,
            maximumAllocationBytes: bytesLimit))
        let preparationFinished = ProcessInfo.processInfo.systemUptime
        let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
        let executionFinished = ProcessInfo.processInfo.systemUptime
        _ = try await SPICEIO.exportToCSV(output.waveform, path: arguments[1])
        let exported = ProcessInfo.processInfo.systemUptime
        let reloaded = try CSVWaveformReader().read(contentsOfFile: arguments[1])
        let savedNames = reloaded.variables.map(\.name), actualNames = output.waveform.variables.map(\.name)
        guard savedNames == actualNames else {
            let first = zip(savedNames, actualNames).enumerated().first { $0.element.0 != $0.element.1 }
            throw Failure.roundtripMismatch("metadata.variables savedCount=\(savedNames.count) actualCount=\(actualNames.count) firstDifference=\(String(describing: first))")
        }
        guard reloaded.pointCount == output.waveform.pointCount else {
            throw Failure.roundtripMismatch("metadata.pointCount saved=\(reloaded.pointCount) actual=\(output.waveform.pointCount)")
        }
        guard reloaded.isComplex == output.waveform.isComplex else {
            throw Failure.roundtripMismatch("metadata.isComplex saved=\(reloaded.isComplex) actual=\(output.waveform.isComplex)")
        }
        var maximumRoundtripError = 0.0
        for point in 0..<output.waveform.pointCount {
            guard let savedCoordinate = reloaded.sweepValue(at: point),
                  let coordinate = output.waveform.sweepValue(at: point) else {
                throw Failure.missingValue("coordinate point=\(point) csvLine=\(point + 2) savedCount=\(reloaded.sweepValues.count) actualCount=\(output.waveform.sweepValues.count)")
            }
            let coordinateBound = csvRoundtripBound(saved: savedCoordinate, actual: coordinate)
            guard abs(savedCoordinate - coordinate) <= coordinateBound else {
                throw Failure.roundtripMismatch("coordinate point=\(point) csvLine=\(point + 2) saved=\(number(savedCoordinate)) actual=\(number(coordinate)) absoluteError=\(abs(savedCoordinate - coordinate)) bound=\(coordinateBound)")
            }
            for variable in output.waveform.variables.indices {
                guard let saved = reloaded.complexValue(variable: variable, point: point),
                      let actual = output.waveform.complexValue(variable: variable, point: point),
                      actual.real.isFinite, actual.imag.isFinite else {
                    throw Failure.missingValue("value point=\(point) csvLine=\(point + 2) variable=\(variable) name=\(actualNames[variable])")
                }
                for (lane, lhs, rhs) in [("real", saved.real, actual.real), ("imag", saved.imag, actual.imag)] {
                    let error = abs(lhs - rhs), bound = csvRoundtripBound(saved: lhs, actual: rhs)
                    guard error <= bound else {
                        throw Failure.roundtripMismatch("value point=\(point) csvLine=\(point + 2) variable=\(variable) name=\(actualNames[variable]) lane=\(lane) coordinate=\(number(coordinate)) savedCoordinate=\(number(savedCoordinate)) saved=\(number(lhs)) actual=\(number(rhs)) absoluteError=\(error) bound=\(bound)")
                    }
                    maximumRoundtripError = max(maximumRoundtripError, error)
                }
            }
        }
        let finished = ProcessInfo.processInfo.systemUptime
        let receipt = Receipt(sourceSHA256: digest.digest.hexadecimalValue,
            sourceInputIdentity: output.sourceInputIdentity.hexadecimalValue,
            configurationIdentity: output.configurationIdentity.hexadecimalValue,
            solverIdentity: output.prepared.solverIdentity,
            algorithmIdentity: output.prepared.algorithmIdentity,
            maximumAdmittedBytes: bytesLimit, maximumLiveOwnedBytes: liveBytes, maximumResolutionRetainedBytes: bytesLimit / 8, maximumWorkUnits: input.configuration.numericalLimits.maximumWorkUnits,
            frontendSeconds: frontendFinished - started,
            nativePreparationSeconds: preparationFinished - frontendFinished,
            executionSeconds: executionFinished - preparationFinished,
            exportSeconds: exported - executionFinished, reloadSeconds: finished - exported,
            measuredTotalSeconds: finished - started, variableNames: reloaded.variables.map(\.name),
            coordinates: reloaded.sweepValues, statistics: output.statistics,
            phases: output.phases.map { Phase(analysis: $0.analysis, points: $0.completedPointCount) },
            maximumCSVRoundtripAbsoluteError: maximumRoundtripError)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(receipt)
        try encoded.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
        let restored = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        guard restored == receipt else { throw Failure.roundtripMismatch("JSON receipt differs after exact Codable reload") }
        print(String(decoding: encoded, as: UTF8.self))
    }
    // Default CSV uses 15 significant decimal digits; parsing may add one binary64 ulp.
    private static func csvRoundtripBound(saved: Double, actual: Double) -> Double {
        actual == 0 ? 0 : 5e-15 * abs(actual) + max(actual.ulp, saved.ulp)
    }
    private static func number(_ value: Double) -> String {
        "\(String(reflecting: value)) bits=0x\(String(value.bitPattern, radix: 16)) ulp=\(value.ulp)"
    }
    private struct NoIncludes: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw Failure.unexpectedInclude(binding.key)
        }
    }
    private struct Phase: Codable, Equatable { let analysis: String; let points: Int }
    private struct Receipt: Codable, Equatable {
        let sourceSHA256: String
        let sourceInputIdentity: String
        let configurationIdentity: String
        let solverIdentity: String
        let algorithmIdentity: String
        let maximumAdmittedBytes: UInt64
        let maximumLiveOwnedBytes: UInt64
        let maximumResolutionRetainedBytes: UInt64
        let maximumWorkUnits: Int
        let frontendSeconds: Double
        let nativePreparationSeconds: Double
        let executionSeconds: Double
        let exportSeconds: Double
        let reloadSeconds: Double
        let measuredTotalSeconds: Double
        let variableNames: [String]
        let coordinates: [Double]
        let statistics: TransientExecutionStatistics
        let phases: [Phase]
        let maximumCSVRoundtripAbsoluteError: Double
    }
}
