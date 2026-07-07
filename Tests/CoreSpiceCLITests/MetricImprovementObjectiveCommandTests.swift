import CoreSpice
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("CoreSpice metric improvement objective command")
struct MetricImprovementObjectiveCommandTests {
    @Test func commandWritesMetricImprovementPlanningProblem() throws {
        let root = try makeTemporaryRoot("metric-improvement-command")
        defer { removeTemporaryRoot(root) }
        let measurementPath = root.appending(path: "measurement-report.json")
        let specificationPath = root.appending(path: "specification.json")
        let parameterSpacePath = root.appending(path: "parameter-space.json")
        let outputPath = root.appending(path: "metric-improvement-problem.json")

        try writeJSON(
            CoreSpiceMetricMeasurementReport(
                runID: "sim-run-1",
                metrics: [
                    CoreSpiceMetricMeasurement(name: "gain", value: 0.82, unit: "ratio"),
                    CoreSpiceMetricMeasurement(name: "delay", value: 1.7e-9, unit: "s"),
                ]
            ),
            to: measurementPath
        )
        try writeJSON(
            CoreSpiceMetricSpecificationSet(specifications: [
                CoreSpiceMetricSpecification(name: "gain", minimum: 0.90, weight: 2),
                CoreSpiceMetricSpecification(name: "delay", maximum: 2.0e-9),
            ]),
            to: specificationPath
        )
        try writeJSON(
            CoreSpiceMetricParameterSpace(parameters: [
                CoreSpiceBoundedParameter(
                    name: "R1",
                    lowerBound: 500,
                    upperBound: 1500,
                    nominalValue: 1000,
                    step: 250,
                    unit: "ohm"
                ),
            ]),
            to: parameterSpacePath
        )

        let command = try CoreSpiceMetricImprovementObjectiveCommand(arguments: [
            "--measurement-report",
            measurementPath.path(percentEncoded: false),
            "--specification",
            specificationPath.path(percentEncoded: false),
            "--parameter-space",
            parameterSpacePath.path(percentEncoded: false),
            "--output",
            outputPath.path(percentEncoded: false),
            "--problem-id",
            "gain-recovery",
            "--created-at",
            "2026-06-30T00:00:00Z",
            "--pretty",
        ])
        try command.run()

        let problem = try readJSON(
            CoreSpiceMetricImprovementPlanningProblem.self,
            from: outputPath
        )
        #expect(problem.schemaVersion == 1)
        #expect(problem.problemID == "gain-recovery")
        #expect(problem.status == "requires-improvement")
        #expect(problem.objectives.count == 1)
        let objective = try #require(problem.objectives.first)
        #expect(objective.objectiveID == "metric-gain-objective")
        #expect(objective.metricName == "gain")
        #expect(objective.currentValue == 0.82)
        #expect(objective.requiredMinimum == 0.90)
        #expect(objective.direction == "increase")
        #expect(abs(objective.magnitude - 0.08) < 1.0e-12)
        #expect(objective.weight == 2)
        #expect(objective.unit == "ratio")
        #expect(problem.parameterSpace.parameters.first?.name == "R1")
        #expect(problem.sourceRefs.map(\.refID) == [
            "measurement-report",
            "specification-ref",
            "bounded-parameter-space",
        ])
        #expect(problem.suggestedActions.contains("set-netlist-parameters"))
        #expect(problem.verificationGates.contains("simulation-metric-gate"))
        #expect(problem.verificationGates.contains("artifact-integrity"))
    }

    @Test func builderRejectsInvalidParameterBounds() throws {
        let request = CoreSpiceMetricImprovementObjectiveRequest(
            problemID: "invalid-bounds",
            createdAt: "2026-06-30T00:00:00Z",
            measurementReport: CoreSpiceMetricMeasurementReport(metrics: [
                CoreSpiceMetricMeasurement(name: "gain", value: 0.82),
            ]),
            specificationSet: CoreSpiceMetricSpecificationSet(specifications: [
                CoreSpiceMetricSpecification(name: "gain", minimum: 0.90),
            ]),
            parameterSpace: CoreSpiceMetricParameterSpace(parameters: [
                CoreSpiceBoundedParameter(name: "R1", lowerBound: 1500, upperBound: 500),
            ])
        )

        #expect(throws: CoreSpiceMetricImprovementObjectiveError.invalidParameterBounds("R1")) {
            _ = try CoreSpiceMetricImprovementObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderRejectsNonFiniteMetricValue() throws {
        let request = CoreSpiceMetricImprovementObjectiveRequest(
            problemID: "invalid-metric-value",
            createdAt: "2026-06-30T00:00:00Z",
            measurementReport: CoreSpiceMetricMeasurementReport(metrics: [
                CoreSpiceMetricMeasurement(name: "gain", value: .nan),
            ]),
            specificationSet: CoreSpiceMetricSpecificationSet(specifications: [
                CoreSpiceMetricSpecification(name: "gain", minimum: 0.90),
            ]),
            parameterSpace: CoreSpiceMetricParameterSpace(parameters: [
                CoreSpiceBoundedParameter(name: "R1", lowerBound: 500, upperBound: 1500),
            ])
        )

        #expect(throws: CoreSpiceMetricImprovementObjectiveError.invalidMetricValue("gain")) {
            _ = try CoreSpiceMetricImprovementObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderRejectsInvalidSpecificationBounds() throws {
        let request = CoreSpiceMetricImprovementObjectiveRequest(
            problemID: "invalid-specification-bounds",
            createdAt: "2026-06-30T00:00:00Z",
            measurementReport: CoreSpiceMetricMeasurementReport(metrics: [
                CoreSpiceMetricMeasurement(name: "gain", value: 0.82),
            ]),
            specificationSet: CoreSpiceMetricSpecificationSet(specifications: [
                CoreSpiceMetricSpecification(name: "gain", minimum: 1.10, maximum: 0.90),
            ]),
            parameterSpace: CoreSpiceMetricParameterSpace(parameters: [
                CoreSpiceBoundedParameter(name: "R1", lowerBound: 500, upperBound: 1500),
            ])
        )

        #expect(throws: CoreSpiceMetricImprovementObjectiveError.invalidSpecificationBounds("gain")) {
            _ = try CoreSpiceMetricImprovementObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderRejectsNegativeSpecificationTolerance() throws {
        let request = CoreSpiceMetricImprovementObjectiveRequest(
            problemID: "invalid-specification-tolerance",
            createdAt: "2026-06-30T00:00:00Z",
            measurementReport: CoreSpiceMetricMeasurementReport(metrics: [
                CoreSpiceMetricMeasurement(name: "gain", value: 0.82),
            ]),
            specificationSet: CoreSpiceMetricSpecificationSet(specifications: [
                CoreSpiceMetricSpecification(name: "gain", target: 1.0, tolerance: -0.01),
            ]),
            parameterSpace: CoreSpiceMetricParameterSpace(parameters: [
                CoreSpiceBoundedParameter(name: "R1", lowerBound: 500, upperBound: 1500),
            ])
        )

        #expect(throws: CoreSpiceMetricImprovementObjectiveError.invalidSpecificationBounds("gain")) {
            _ = try CoreSpiceMetricImprovementObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderRejectsNonPositiveParameterStep() throws {
        let request = CoreSpiceMetricImprovementObjectiveRequest(
            problemID: "invalid-parameter-step",
            createdAt: "2026-06-30T00:00:00Z",
            measurementReport: CoreSpiceMetricMeasurementReport(metrics: [
                CoreSpiceMetricMeasurement(name: "gain", value: 0.82),
            ]),
            specificationSet: CoreSpiceMetricSpecificationSet(specifications: [
                CoreSpiceMetricSpecification(name: "gain", minimum: 0.90),
            ]),
            parameterSpace: CoreSpiceMetricParameterSpace(parameters: [
                CoreSpiceBoundedParameter(name: "R1", lowerBound: 500, upperBound: 1500, step: 0),
            ])
        )

        #expect(throws: CoreSpiceMetricImprovementObjectiveError.invalidParameterStep("R1")) {
            _ = try CoreSpiceMetricImprovementObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func commandRejectsUnknownArgument() throws {
        #expect(throws: CLIError.self) {
            _ = try CoreSpiceMetricImprovementObjectiveCommand(arguments: ["--unknown"])
        }
    }

    private func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MetricImprovementObjectiveCommandTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeTemporaryRoot(_ root: URL) {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Failed to remove temporary root \(root.path(percentEncoded: false)): \(error)")
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }
}
