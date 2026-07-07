import CoreSpice
import Foundation

struct CoreSpiceConvergenceRecoveryObjectiveCommand: Sendable {
    let diagnosticReportPath: String
    let netlistPath: String
    let analysisOptionsPath: String
    let retryPolicyPath: String?
    let outputPath: String?
    let problemID: String
    let createdAt: String
    let pretty: Bool

    init(arguments: [String]) throws {
        var diagnosticReportPath: String?
        var netlistPath: String?
        var analysisOptionsPath: String?
        var retryPolicyPath: String?
        var outputPath: String?
        var problemID = "corespice-convergence-recovery-problem"
        var createdAt: String?
        var pretty = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--diagnostic-report":
                diagnosticReportPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--netlist":
                netlistPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--analysis-options":
                analysisOptionsPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--retry-policy":
                retryPolicyPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--output":
                outputPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--problem-id":
                problemID = try Self.value(after: argument, in: arguments, at: &index)
            case "--created-at":
                createdAt = try Self.value(after: argument, in: arguments, at: &index)
            case "--pretty":
                pretty = true
                index += 1
            default:
                throw CLIError.invalidArguments("unknown convergence-recovery-objective argument: \(argument)")
            }
        }

        guard let diagnosticReportPath else {
            throw CLIError.invalidArguments("missing --diagnostic-report <path>")
        }
        guard let netlistPath else {
            throw CLIError.invalidArguments("missing --netlist <path>")
        }
        guard let analysisOptionsPath else {
            throw CLIError.invalidArguments("missing --analysis-options <path>")
        }

        self.diagnosticReportPath = diagnosticReportPath
        self.netlistPath = netlistPath
        self.analysisOptionsPath = analysisOptionsPath
        self.retryPolicyPath = retryPolicyPath
        self.outputPath = outputPath
        self.problemID = problemID
        self.createdAt = createdAt ?? ISO8601DateFormatter().string(from: Date())
        self.pretty = pretty
    }

    func run() throws {
        let decoder = JSONDecoder()
        let diagnosticReport = try Self.readJSON(
            CoreSpiceConvergenceDiagnosticReport.self,
            from: diagnosticReportPath,
            decoder: decoder
        )
        let analysisOptions = try Self.readJSON(
            CoreSpiceConvergenceAnalysisOptions.self,
            from: analysisOptionsPath,
            decoder: decoder
        )
        let retryPolicy: CoreSpiceConvergenceRetryPolicy
        if let retryPolicyPath {
            retryPolicy = try Self.readJSON(
                CoreSpiceConvergenceRetryPolicy.self,
                from: retryPolicyPath,
                decoder: decoder
            )
        } else {
            retryPolicy = CoreSpiceConvergenceRetryPolicy()
        }

        let netlistRef = CoreSpiceConvergenceSourceRef(
            refID: "spice-netlist-ref",
            path: netlistPath,
            kind: "spice-netlist"
        )
        let request = CoreSpiceConvergenceRecoveryObjectiveRequest(
            problemID: problemID,
            createdAt: createdAt,
            diagnosticReport: diagnosticReport,
            netlistRef: netlistRef,
            analysisOptions: analysisOptions,
            retryPolicy: retryPolicy,
            sourceRefs: [
                CoreSpiceConvergenceSourceRef(
                    refID: "simulation-diagnostic",
                    path: diagnosticReportPath,
                    kind: "simulation-diagnostic"
                ),
                netlistRef,
                CoreSpiceConvergenceSourceRef(
                    refID: "analysis-options",
                    path: analysisOptionsPath,
                    kind: "analysis-options"
                ),
            ]
        )
        let problem = try CoreSpiceConvergenceRecoveryObjectiveBuilder().makePlanningProblem(request: request)
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        let data = try encoder.encode(problem)
        if let outputPath {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func value(after flag: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIError.invalidArguments("missing value after \(flag)")
        }
        index += 2
        return arguments[valueIndex]
    }

    private static func readJSON<T: Decodable>(
        _ type: T.Type,
        from path: String,
        decoder: JSONDecoder
    ) throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decoder.decode(type, from: data)
    }
}
