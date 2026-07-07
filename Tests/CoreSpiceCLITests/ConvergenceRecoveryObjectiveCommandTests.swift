import CoreSpice
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("CoreSpice convergence recovery objective command")
struct ConvergenceRecoveryObjectiveCommandTests {
    @Test func commandWritesConvergenceRecoveryPlanningProblem() throws {
        let root = try makeTemporaryRoot("convergence-recovery-command")
        defer { removeTemporaryRoot(root) }
        let diagnosticPath = root.appending(path: "diagnostics.json")
        let netlistPath = root.appending(path: "oscillator.cir")
        let optionsPath = root.appending(path: "analysis-options.json")
        let outputPath = root.appending(path: "convergence-recovery-problem.json")

        try Data("* oscillator\n.end\n".utf8).write(to: netlistPath, options: .atomic)
        try writeJSON(
            CoreSpiceConvergenceDiagnosticReport(
                runID: "sim-run-2",
                analysisType: "tran",
                diagnostics: [
                    CoreSpiceConvergenceDiagnostic(
                        severity: "error",
                        code: "timestep-too-small",
                        message: "Transient timestep became too small near an edge.",
                        component: "M1",
                        iteration: 40,
                        residualNorm: 1.2e-3,
                        time: 2.5e-9
                    ),
                ]
            ),
            to: diagnosticPath
        )
        try writeJSON(
            CoreSpiceConvergenceAnalysisOptions(
                analysisType: "tran",
                reltol: 1.0e-4,
                maxIterations: 50,
                gmin: 1.0e-13,
                timestep: 1.0e-10,
                stopTime: 1.0e-6,
                integrationMethod: "trapezoidal"
            ),
            to: optionsPath
        )

        let command = try CoreSpiceConvergenceRecoveryObjectiveCommand(arguments: [
            "--diagnostic-report",
            diagnosticPath.path(percentEncoded: false),
            "--netlist",
            netlistPath.path(percentEncoded: false),
            "--analysis-options",
            optionsPath.path(percentEncoded: false),
            "--output",
            outputPath.path(percentEncoded: false),
            "--problem-id",
            "tran-convergence-recovery",
            "--created-at",
            "2026-06-30T00:00:00Z",
            "--pretty",
        ])
        try command.run()

        let problem = try readJSON(
            CoreSpiceConvergenceRecoveryPlanningProblem.self,
            from: outputPath
        )
        #expect(problem.schemaVersion == 1)
        #expect(problem.problemID == "tran-convergence-recovery")
        #expect(problem.status == "requires-retry")
        #expect(problem.analysisType == "tran")
        #expect(problem.objectives.count == 1)
        let objective = try #require(problem.objectives.first)
        #expect(objective.target == "restore-simulation-convergence")
        #expect(objective.diagnosticCode == "timestep-too-small")
        #expect(objective.component == "M1")
        #expect(problem.retryOptions.contains {
            $0.optionID == "increase-max-iterations"
                && $0.parameterName == "maxIterations"
                && $0.currentValue == 50
                && $0.proposedValue == 100
        })
        #expect(problem.retryOptions.contains {
            $0.optionID == "raise-gmin"
                && $0.parameterName == "gmin"
                && $0.currentValue == 1.0e-13
                && $0.proposedValue == 1.0e-12
        })
        #expect(problem.retryOptions.contains {
            $0.optionID == "reduce-timestep"
                && $0.parameterName == "timestep"
                && $0.currentValue == 1.0e-10
                && $0.proposedValue == 5.0e-11
        })
        #expect(problem.retryOptions.contains {
            $0.optionID == "switch-to-backward-euler"
                && $0.action == "switch-integration-method"
        })
        #expect(problem.sourceRefs.map(\.refID) == [
            "simulation-diagnostic",
            "spice-netlist-ref",
            "analysis-options",
        ])
        #expect(problem.verificationGates.contains("simulation-completed"))
        #expect(problem.verificationGates.contains("artifact-integrity"))
    }

    @Test func builderRejectsInvalidRetryPolicy() throws {
        let request = CoreSpiceConvergenceRecoveryObjectiveRequest(
            problemID: "invalid-policy",
            createdAt: "2026-06-30T00:00:00Z",
            diagnosticReport: CoreSpiceConvergenceDiagnosticReport(
                analysisType: "op",
                diagnostics: [
                    CoreSpiceConvergenceDiagnostic(
                        severity: "error",
                        code: "convergence-stall",
                        message: "Newton residual stalled."
                    ),
                ]
            ),
            netlistRef: CoreSpiceConvergenceSourceRef(
                refID: "spice-netlist-ref",
                path: "input.cir",
                kind: "spice-netlist"
            ),
            analysisOptions: CoreSpiceConvergenceAnalysisOptions(analysisType: "op"),
            retryPolicy: CoreSpiceConvergenceRetryPolicy(timestepScale: 1.2)
        )

        #expect(throws: CoreSpiceConvergenceRecoveryObjectiveError.invalidRetryPolicy(
            "timestepScale must be between 0 and 1"
        )) {
            _ = try CoreSpiceConvergenceRecoveryObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderRejectsDiagnosticsWithoutMachineReadableCode() throws {
        let request = CoreSpiceConvergenceRecoveryObjectiveRequest(
            problemID: "missing-diagnostic-code",
            createdAt: "2026-06-30T00:00:00Z",
            diagnosticReport: CoreSpiceConvergenceDiagnosticReport(
                analysisType: "tran",
                diagnostics: [
                    CoreSpiceConvergenceDiagnostic(
                        severity: "error",
                        code: " ",
                        message: "Transient timestep became too small."
                    ),
                ]
            ),
            netlistRef: CoreSpiceConvergenceSourceRef(
                refID: "spice-netlist-ref",
                path: "input.cir",
                kind: "spice-netlist"
            ),
            analysisOptions: CoreSpiceConvergenceAnalysisOptions(analysisType: "tran")
        )

        #expect(throws: CoreSpiceConvergenceRecoveryObjectiveError.emptyDiagnosticField(
            index: 1,
            field: "code"
        )) {
            _ = try CoreSpiceConvergenceRecoveryObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderRejectsAnalysisTypeMismatch() throws {
        let request = CoreSpiceConvergenceRecoveryObjectiveRequest(
            problemID: "analysis-type-mismatch",
            createdAt: "2026-06-30T00:00:00Z",
            diagnosticReport: CoreSpiceConvergenceDiagnosticReport(
                analysisType: "tran",
                diagnostics: [
                    CoreSpiceConvergenceDiagnostic(
                        severity: "error",
                        code: "timestep-too-small",
                        message: "Transient timestep became too small."
                    ),
                ]
            ),
            netlistRef: CoreSpiceConvergenceSourceRef(
                refID: "spice-netlist-ref",
                path: "input.cir",
                kind: "spice-netlist"
            ),
            analysisOptions: CoreSpiceConvergenceAnalysisOptions(analysisType: "op")
        )

        #expect(throws: CoreSpiceConvergenceRecoveryObjectiveError.analysisTypeMismatch(
            report: "tran",
            options: "op"
        )) {
            _ = try CoreSpiceConvergenceRecoveryObjectiveBuilder().makePlanningProblem(request: request)
        }
    }

    @Test func builderKeepsRequiredNetlistRefWhenCustomSourceRefsOmitIt() throws {
        let request = CoreSpiceConvergenceRecoveryObjectiveRequest(
            problemID: "custom-source-refs",
            createdAt: "2026-06-30T00:00:00Z",
            diagnosticReport: CoreSpiceConvergenceDiagnosticReport(
                analysisType: "tran",
                diagnostics: [
                    CoreSpiceConvergenceDiagnostic(
                        severity: "error",
                        code: "timestep-too-small",
                        message: "Transient timestep became too small.",
                        component: " M1 ",
                        suggestedActions: [" ", "reduce-local-timestep"]
                    ),
                ]
            ),
            netlistRef: CoreSpiceConvergenceSourceRef(
                refID: "spice-netlist-ref",
                path: "input.cir",
                kind: "spice-netlist"
            ),
            analysisOptions: CoreSpiceConvergenceAnalysisOptions(
                analysisType: "tran",
                timestep: 1.0e-9
            ),
            sourceRefs: [
                CoreSpiceConvergenceSourceRef(
                    refID: "simulation-diagnostic",
                    path: "diagnostics.json",
                    kind: "simulation-diagnostic"
                ),
            ]
        )

        let problem = try CoreSpiceConvergenceRecoveryObjectiveBuilder().makePlanningProblem(request: request)

        #expect(problem.sourceRefs.map(\.refID) == [
            "simulation-diagnostic",
            "spice-netlist-ref",
        ])
        let diagnostic = try #require(problem.diagnostics.first)
        #expect(diagnostic.component == "M1")
        #expect(diagnostic.suggestedActions == ["reduce-local-timestep"])
    }

    @Test func legacyDiagnosticJSONDecodesWithoutSuggestedActions() throws {
        let json = """
        {
          "severity": "error",
          "code": "newton-stalled",
          "message": "Newton residual stalled."
        }
        """
        let diagnostic = try JSONDecoder().decode(
            CoreSpiceConvergenceDiagnostic.self,
            from: Data(json.utf8)
        )

        #expect(diagnostic.suggestedActions.isEmpty)
    }

    @Test func commandRejectsUnknownArgument() throws {
        #expect(throws: CLIError.self) {
            _ = try CoreSpiceConvergenceRecoveryObjectiveCommand(arguments: ["--unknown"])
        }
    }

    private func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ConvergenceRecoveryObjectiveCommandTests-\(name)-\(UUID().uuidString)")
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
