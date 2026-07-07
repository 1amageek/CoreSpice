import CoreSpice
import Foundation

struct CoreSpiceMetricImprovementObjectiveCommand: Sendable {
    let measurementReportPath: String
    let specificationPath: String
    let parameterSpacePath: String
    let outputPath: String?
    let problemID: String
    let createdAt: String
    let pretty: Bool

    init(arguments: [String]) throws {
        var measurementReportPath: String?
        var specificationPath: String?
        var parameterSpacePath: String?
        var outputPath: String?
        var problemID = "corespice-metric-improvement-problem"
        var createdAt: String?
        var pretty = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--measurement-report":
                measurementReportPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--specification":
                specificationPath = try Self.value(after: argument, in: arguments, at: &index)
            case "--parameter-space":
                parameterSpacePath = try Self.value(after: argument, in: arguments, at: &index)
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
                throw CLIError.invalidArguments("unknown metric-improvement-objective argument: \(argument)")
            }
        }

        guard let measurementReportPath else {
            throw CLIError.invalidArguments("missing --measurement-report <path>")
        }
        guard let specificationPath else {
            throw CLIError.invalidArguments("missing --specification <path>")
        }
        guard let parameterSpacePath else {
            throw CLIError.invalidArguments("missing --parameter-space <path>")
        }

        self.measurementReportPath = measurementReportPath
        self.specificationPath = specificationPath
        self.parameterSpacePath = parameterSpacePath
        self.outputPath = outputPath
        self.problemID = problemID
        self.createdAt = createdAt ?? ISO8601DateFormatter().string(from: Date())
        self.pretty = pretty
    }

    func run() throws {
        let decoder = JSONDecoder()
        let measurementReport = try Self.readJSON(
            CoreSpiceMetricMeasurementReport.self,
            from: measurementReportPath,
            decoder: decoder
        )
        let specificationSet = try Self.readJSON(
            CoreSpiceMetricSpecificationSet.self,
            from: specificationPath,
            decoder: decoder
        )
        let parameterSpace = try Self.readJSON(
            CoreSpiceMetricParameterSpace.self,
            from: parameterSpacePath,
            decoder: decoder
        )
        let request = CoreSpiceMetricImprovementObjectiveRequest(
            problemID: problemID,
            createdAt: createdAt,
            measurementReport: measurementReport,
            specificationSet: specificationSet,
            parameterSpace: parameterSpace,
            sourceRefs: [
                CoreSpiceMetricImprovementSourceRef(
                    refID: "measurement-report",
                    path: measurementReportPath,
                    kind: "measurement-report"
                ),
                CoreSpiceMetricImprovementSourceRef(
                    refID: "specification-ref",
                    path: specificationPath,
                    kind: "metric-specification"
                ),
                CoreSpiceMetricImprovementSourceRef(
                    refID: "bounded-parameter-space",
                    path: parameterSpacePath,
                    kind: "parameter-space"
                ),
            ]
        )
        let problem = try CoreSpiceMetricImprovementObjectiveBuilder().makePlanningProblem(request: request)
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
