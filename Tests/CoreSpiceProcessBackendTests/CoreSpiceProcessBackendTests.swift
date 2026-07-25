import CircuiteFoundation
import CoreSpice
@testable import CoreSpiceProcessBackend
import Foundation
import Testing

@Suite("CoreSpice external process backend")
struct CoreSpiceProcessBackendTests {
    @Test("Foundation runner captures process output")
    func foundationRunnerCapturesProcessOutput() async throws {
        try await withTemporaryDirectory { directory in
            let outputURL = directory.appendingPathComponent("stdout")
            let errorURL = directory.appendingPathComponent("stderr")
            let result = try await FoundationCoreSpiceProcessRunner().run(
                CoreSpiceProcessInvocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                    arguments: ["captured"],
                    workingDirectoryURL: directory,
                    standardOutputURL: outputURL,
                    standardErrorURL: errorURL
                )
            )

            #expect(result.terminationStatus == 0)
            #expect(String(decoding: result.standardOutput, as: UTF8.self) == "captured")
            #expect(result.standardError.isEmpty)
        }
    }

    @Test("Foundation runner terminates a cancelled process")
    func foundationRunnerHandlesCancellation() async throws {
        try await withTemporaryDirectory { directory in
            let runner = FoundationCoreSpiceProcessRunner()
            let task = Task {
                try await runner.run(
                    CoreSpiceProcessInvocation(
                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["30"],
                        workingDirectoryURL: directory,
                        standardOutputURL: directory.appendingPathComponent("stdout"),
                        standardErrorURL: directory.appendingPathComponent("stderr")
                    )
                )
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }
        }
    }

    @Test("Backend verifies declared inputs and emitted artifacts")
    func backendExecutesVerifiedRequest() async throws {
        try await withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("input.cir")
            try Data("V1 in 0 1\nR1 in 0 1k\n.op\n.end\n".utf8).write(to: inputURL)
            let input = try reference(
                inputURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let runRoot = directory.appendingPathComponent("runs", isDirectory: true)
            let runner = RecordingProcessRunner(mode: .succeed(inputs: [input]))
            let backend = try CoreSpiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                runRootURL: runRoot,
                processRunner: runner,
                environment: try ExecutionEnvironmentFingerprint(
                    platform: "test",
                    architecture: "test",
                    toolchain: "test"
                )
            )

            let execution = try await backend.execute(
                CoreSpiceSimulationRequest(
                    inputs: [input],
                    primaryInputID: input.id,
                    randomSeed: 17
                )
            )

            #expect(execution.invocation.mode == .externalProcess)
            #expect(execution.invocation.arguments.suffix(2) == ["--seed", "17"])
            #expect(execution.artifacts.count == 4)
            for artifact in execution.artifacts {
                #expect(LocalArtifactVerifier().verify(artifact, relativeTo: nil).isVerified)
            }
            #expect(await runner.invocationCount == 1)
        }
    }

    @Test("Backend executes the built CoreSpice CLI")
    func backendExecutesBuiltCLI() async throws {
        try await withTemporaryDirectory { directory in
            let executableURL = Bundle(for: TestBundleMarker.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("corespice")
            #expect(FileManager.default.isExecutableFile(atPath: executableURL.path))

            let inputURL = directory.appendingPathComponent("input.cir")
            try Data(
                """
                V1 in 0 PULSE(0 1 0 1n 1n 2u 4u)
                R1 in out 1k
                C1 out 0 1n
                .tran 100n 2u
                .end

                """.utf8
            ).write(to: inputURL)
            let input = try reference(
                inputURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let backend = try CoreSpiceExternalProcessBackend(
                executableURL: executableURL,
                runRootURL: directory.appendingPathComponent("runs")
            )

            let execution = try await backend.execute(
                CoreSpiceSimulationRequest(
                    inputs: [input],
                    primaryInputID: input.id,
                    randomSeed: 29
                )
            )

            #expect(execution.artifacts.contains { $0.locator.format == .raw })
            #expect(execution.artifacts.contains { $0.locator.format == .json })
            for artifact in execution.artifacts {
                #expect(LocalArtifactVerifier().verify(artifact, relativeTo: nil).isVerified)
            }
        }
    }

    @Test("Backend rejects an input changed after declaration")
    func backendRejectsTamperedInputBeforeLaunch() async throws {
        try await withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("input.cir")
            try Data(".op\n.end\n".utf8).write(to: inputURL)
            let input = try reference(
                inputURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            try Data(".tran 1n 1u\n.end\n".utf8).write(to: inputURL)
            let runner = RecordingProcessRunner(mode: .succeed(inputs: [input]))
            let backend = try CoreSpiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                runRootURL: directory.appendingPathComponent("runs"),
                processRunner: runner
            )

            await #expect(throws: CoreSpiceProcessBackendError.self) {
                try await backend.execute(
                    CoreSpiceSimulationRequest(
                        inputs: [input],
                        primaryInputID: input.id,
                        randomSeed: 1
                    )
                )
            }
            #expect(await runner.invocationCount == 0)
        }
    }

    @Test("Backend rejects a request without an explicit seed")
    func backendRejectsMissingSeedBeforeLaunch() async throws {
        try await withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("input.cir")
            try Data(".op\n.end\n".utf8).write(to: inputURL)
            let input = try reference(
                inputURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let runner = RecordingProcessRunner(mode: .succeed(inputs: [input]))
            let backend = try CoreSpiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                runRootURL: directory.appendingPathComponent("runs"),
                processRunner: runner
            )

            await #expect(
                throws: CoreSpiceProcessBackendError.missingRandomSeed
            ) {
                try await backend.execute(
                    CoreSpiceSimulationRequest(
                        inputs: [input],
                        primaryInputID: input.id,
                        randomSeed: nil
                    )
                )
            }
            #expect(await runner.invocationCount == 0)
        }
    }

    @Test("Backend rejects undeclared include inputs")
    func backendRejectsUndeclaredInputs() async throws {
        try await withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("input.cir")
            let includeURL = directory.appendingPathComponent("models.inc")
            try Data(".op\n.end\n".utf8).write(to: inputURL)
            try Data(".model D D\n".utf8).write(to: includeURL)
            let input = try reference(
                inputURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let include = try reference(
                includeURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let backend = try CoreSpiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                runRootURL: directory.appendingPathComponent("runs"),
                processRunner: RecordingProcessRunner(
                    mode: .succeed(inputs: [input, include])
                )
            )

            await #expect(
                throws: CoreSpiceProcessBackendError.unexpectedInputArtifacts
            ) {
                try await backend.execute(
                    CoreSpiceSimulationRequest(
                        inputs: [input],
                        primaryInputID: input.id,
                        randomSeed: 1
                    )
                )
            }
        }
    }

    @Test("Backend preserves a structured CLI failure")
    func backendReportsStructuredFailure() async throws {
        try await withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("input.cir")
            try Data(".op\n.end\n".utf8).write(to: inputURL)
            let input = try reference(
                inputURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let backend = try CoreSpiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                runRootURL: directory.appendingPathComponent("runs"),
                processRunner: RecordingProcessRunner(
                    mode: .fail(
                        status: 2,
                        code: "analysis.non-convergence",
                        message: "Newton iteration did not converge.",
                        stage: "analysis"
                    )
                )
            )

            do {
                _ = try await backend.execute(
                    CoreSpiceSimulationRequest(
                        inputs: [input],
                        primaryInputID: input.id,
                        randomSeed: 1
                    )
                )
                Issue.record("Expected the backend to reject the failed process.")
            } catch let error as CoreSpiceProcessBackendError {
                #expect(
                    error == .processFailed(
                        status: 2,
                        code: "analysis.non-convergence",
                        message: "Newton iteration did not converge.",
                        stage: "analysis"
                    )
                )
            }
        }
    }

    private func reference(
        _ url: URL,
        role: ArtifactRole,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        try LocalArtifactReferencer().reference(
            ArtifactLocator(
                location: try ArtifactLocation(fileURL: url),
                role: role,
                kind: kind,
                format: format
            ),
            relativeTo: nil,
            producer: nil
        )
    }

    private func withTemporaryDirectory<Result>(
        _ operation: (URL) async throws -> Result
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        do {
            let result = try await operation(directory)
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch let cleanupError {
                Issue.record("Temporary directory cleanup failed: \(cleanupError)")
            }
            throw error
        }
    }
}

private actor RecordingProcessRunner: CoreSpiceProcessRunning {
    enum Mode: Sendable {
        case succeed(inputs: [ArtifactReference])
        case fail(status: Int32, code: String, message: String, stage: String?)
    }

    private struct SuccessRecord: Encodable {
        let status: String
        let invocation: ExecutionInvocation
        let inputArtifacts: [ArtifactReference]
        let outputArtifacts: [ArtifactReference]
    }

    private struct FailureRecord: Encodable {
        let status: String
        let code: String
        let message: String
        let stage: String?
    }

    private let mode: Mode
    private(set) var invocationCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func run(
        _ invocation: CoreSpiceProcessInvocation
    ) async throws -> CoreSpiceProcessOutput {
        invocationCount += 1
        switch mode {
        case .succeed(let inputs):
            let rawURL = try argumentValue("-r", in: invocation.arguments)
            let coverageURL = try argumentValue("--coverage-json", in: invocation.arguments)
            try Data("raw".utf8).write(to: URL(fileURLWithPath: rawURL))
            try Data("{}".utf8).write(to: URL(fileURLWithPath: coverageURL))
            let outputs = [
                try reference(
                    URL(fileURLWithPath: rawURL),
                    kind: .waveform,
                    format: .raw
                ),
                try reference(
                    URL(fileURLWithPath: coverageURL),
                    kind: .report,
                    format: .json
                ),
            ]
            let record = SuccessRecord(
                status: "succeeded",
                invocation: try ExecutionInvocation.externalProcess(
                    executable: "corespice",
                    arguments: invocation.arguments,
                    workingDirectory: invocation.workingDirectoryURL.path
                ),
                inputArtifacts: inputs,
                outputArtifacts: outputs
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: invocation.standardOutputURL)
            try Data().write(to: invocation.standardErrorURL)
            return CoreSpiceProcessOutput(
                terminationStatus: 0,
                standardOutput: data,
                standardError: Data()
            )

        case .fail(let status, let code, let message, let stage):
            let data = try JSONEncoder().encode(
                FailureRecord(
                    status: "failed",
                    code: code,
                    message: message,
                    stage: stage
                )
            )
            try data.write(to: invocation.standardOutputURL)
            try Data().write(to: invocation.standardErrorURL)
            return CoreSpiceProcessOutput(
                terminationStatus: status,
                standardOutput: data,
                standardError: Data()
            )
        }
    }

    private func argumentValue(
        _ option: String,
        in arguments: [String]
    ) throws -> String {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            throw TestProcessRunnerError.missingArgument(option)
        }
        return arguments[index + 1]
    }

    private func reference(
        _ url: URL,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        try LocalArtifactReferencer().reference(
            ArtifactLocator(
                location: try ArtifactLocation(fileURL: url),
                role: .output,
                kind: kind,
                format: format
            ),
            relativeTo: nil,
            producer: nil
        )
    }
}

private enum TestProcessRunnerError: Error {
    case missingArgument(String)
}

private final class TestBundleMarker: NSObject {}
