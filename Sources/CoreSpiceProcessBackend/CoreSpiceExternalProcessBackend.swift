import CircuiteFoundation
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
import Foundation

public struct CoreSpiceExternalProcessBackend: CoreSpiceSimulationBackend {
    private struct SuccessfulRecord: Decodable {
        let status: String
        let invocation: ExecutionInvocation
        let inputArtifacts: [ArtifactReference]
        let outputArtifacts: [ArtifactReference]
    }

    private struct FailureRecord: Decodable {
        let status: String
        let code: String
        let message: String
        let stage: String?
    }

    private let executableURL: URL
    private let runRootURL: URL
    private let processRunner: any CoreSpiceProcessRunning
    private let verifier: any ArtifactVerifying
    private let referencer: any ArtifactReferencing
    private let artifactLocator: any CoreSpiceArtifactLocating
    private let environment: ExecutionEnvironmentFingerprint

    public init(
        executableURL: URL,
        runRootURL: URL,
        processRunner: any CoreSpiceProcessRunning = FoundationCoreSpiceProcessRunner(),
        verifier: any ArtifactVerifying = LocalArtifactVerifier(),
        referencer: any ArtifactReferencing = LocalArtifactReferencer(),
        artifactLocator: any CoreSpiceArtifactLocating = CoreSpiceArtifactLocatorRegistry(),
        environment: ExecutionEnvironmentFingerprint? = nil
    ) throws {
        guard runRootURL.isFileURL, runRootURL.path.hasPrefix("/") else {
            throw CoreSpiceProcessBackendError.invalidRunRoot(runRootURL.absoluteString)
        }
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw CoreSpiceProcessBackendError.invalidExecutable(executableURL.path)
        }

        self.executableURL = executableURL.standardizedFileURL
        self.runRootURL = runRootURL.standardizedFileURL
        self.processRunner = processRunner
        self.verifier = verifier
        self.referencer = referencer
        self.artifactLocator = artifactLocator
        self.environment = try environment ?? Self.defaultEnvironment()
    }

    public func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationExecution {
        try Task.checkCancellation()
        guard let randomSeed = request.randomSeed else {
            throw CoreSpiceProcessBackendError.missingRandomSeed
        }
        let inputURLs = try verifyInputs(request.inputs)
        let primaryInput = try primaryInputReference(for: request)
        guard let primaryInputURL = inputURLs[primaryInput.id] else {
            throw CoreSpiceProcessBackendError.primaryInputNotFound(primaryInput.id)
        }

        let runDirectoryURL = runRootURL
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: runDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw CoreSpiceProcessBackendError.invalidRunRoot(error.localizedDescription)
        }

        let rawURL = runDirectoryURL.appendingPathComponent("waveform.raw")
        let coverageURL = runDirectoryURL.appendingPathComponent("coverage.json")
        let standardOutputURL = runDirectoryURL.appendingPathComponent("run.json")
        let standardErrorURL = runDirectoryURL.appendingPathComponent("stderr.log")
        var arguments = [
            "--batch", primaryInputURL.path,
            "-r", rawURL.path,
            "--coverage-json", coverageURL.path,
            "--json",
        ]
        arguments += ["--seed", String(randomSeed)]

        let invocation = try ExecutionInvocation.externalProcess(
            executable: executableURL.path,
            arguments: arguments,
            workingDirectory: runDirectoryURL.path
        )
        let startedAt = Date()
        let output = try await processRunner.run(
            CoreSpiceProcessInvocation(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectoryURL: runDirectoryURL,
                standardOutputURL: standardOutputURL,
                standardErrorURL: standardErrorURL
            )
        )
        let completedAt = Date()

        guard output.terminationStatus == 0 else {
            throw processFailure(from: output)
        }
        let record = try decodeSuccess(from: output.standardOutput)
        guard record.status == "succeeded",
              record.invocation.mode == .externalProcess,
              record.invocation.arguments == arguments,
              record.invocation.workingDirectory.map({
                  URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
              }) == runDirectoryURL.resolvingSymlinksInPath().path else {
            throw CoreSpiceProcessBackendError.malformedProcessOutput(
                "The success record does not describe the requested invocation."
            )
        }
        try verifyReportedInputs(record.inputArtifacts, declared: request.inputs)

        var artifacts = try verifyOutputs(
            record.outputArtifacts,
            expectedLocators: [
                ArtifactLocator(
                    location: try ArtifactLocation(fileURL: rawURL),
                    role: .output,
                    kind: .waveform,
                    format: .raw
                ),
                ArtifactLocator(
                    location: try ArtifactLocation(fileURL: coverageURL),
                    role: .output,
                    kind: .report,
                    format: .json
                ),
            ],
            within: runDirectoryURL
        )
        artifacts.append(
            try referenceLog(
                at: standardOutputURL,
                format: .json
            )
        )
        artifacts.append(
            try referenceLog(
                at: standardErrorURL,
                format: .text
            )
        )

        return try CoreSpiceSimulationExecution(
            artifacts: artifacts,
            invocation: invocation,
            environment: environment,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func verifyInputs(
        _ inputs: [ArtifactReference]
    ) throws -> [ArtifactID: URL] {
        var result: [ArtifactID: URL] = [:]
        for input in inputs {
            let locator: ArtifactLocator
            do {
                locator = try artifactLocator.locator(for: input)
            } catch {
                throw CoreSpiceProcessBackendError.inputLocationInvalid(
                    input.id,
                    reason: String(describing: error)
                )
            }
            let integrity = verifier.verify(input, at: locator, relativeTo: nil)
            guard integrity.isVerified else {
                throw CoreSpiceProcessBackendError.inputIntegrityFailed(
                    input.id,
                    issues: integrity.issues
                )
            }
            do {
                result[input.id] = try locator.location.resolvedFileURL()
            } catch {
                throw CoreSpiceProcessBackendError.inputLocationInvalid(
                    input.id,
                    reason: error.localizedDescription
                )
            }
        }
        return result
    }

    private func primaryInputReference(
        for request: CoreSpiceSimulationRequest
    ) throws -> ArtifactReference {
        if let primaryInputID = request.primaryInputID {
            guard let input = request.inputs.first(where: { $0.id == primaryInputID }) else {
                throw CoreSpiceProcessBackendError.primaryInputNotFound(primaryInputID)
            }
            return input
        }
        let candidates = request.inputs.filter {
            $0.descriptor.kind == .netlist && $0.descriptor.format == .spice
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw CoreSpiceProcessBackendError.ambiguousPrimaryInput(
                candidateCount: candidates.count
            )
        }
        return candidate
    }

    private func decodeSuccess(from data: Data) throws -> SuccessfulRecord {
        do {
            return try JSONDecoder().decode(SuccessfulRecord.self, from: data)
        } catch {
            throw CoreSpiceProcessBackendError.malformedProcessOutput(
                error.localizedDescription
            )
        }
    }

    private func processFailure(
        from output: CoreSpiceProcessOutput
    ) -> CoreSpiceProcessBackendError {
        do {
            let failure = try JSONDecoder().decode(FailureRecord.self, from: output.standardOutput)
            if failure.status == "failed" {
                return .processFailed(
                    status: output.terminationStatus,
                    code: failure.code,
                    message: failure.message,
                    stage: failure.stage
                )
            }
        } catch {
            // Non-JSON process failures are reported using the captured stderr below.
        }
        let message = String(decoding: output.standardError, as: UTF8.self)
        return .processFailed(
            status: output.terminationStatus,
            code: nil,
            message: message.isEmpty ? "No structured failure was emitted." : message,
            stage: nil
        )
    }

    private func verifyReportedInputs(
        _ reported: [ArtifactReference],
        declared: [ArtifactReference]
    ) throws {
        guard Set(reported) == Set(declared) else {
            throw CoreSpiceProcessBackendError.unexpectedInputArtifacts
        }
    }

    private func verifyOutputs(
        _ outputs: [ArtifactReference],
        expectedLocators: [ArtifactLocator],
        within runDirectoryURL: URL
    ) throws -> [ArtifactReference] {
        let rootPath = runDirectoryURL.resolvingSymlinksInPath().path + "/"
        var verifiedOutputs: [ArtifactReference] = []
        for locator in expectedLocators {
            let outputURL: URL
            do {
                outputURL = try locator.location.resolvedFileURL()
                    .resolvingSymlinksInPath()
            } catch {
                throw CoreSpiceProcessBackendError.outputOutsideRunDirectory(
                    locator.location.value
                )
            }
            guard outputURL.path.hasPrefix(rootPath) else {
                throw CoreSpiceProcessBackendError.outputOutsideRunDirectory(
                    outputURL.path
                )
            }
            let output: ArtifactReference
            do {
                output = try referencer.reference(locator, relativeTo: nil)
            } catch {
                throw CoreSpiceProcessBackendError.artifactReferenceFailed(
                    error.localizedDescription
                )
            }
            let integrity = verifier.verify(output, at: locator, relativeTo: nil)
            guard integrity.isVerified else {
                throw CoreSpiceProcessBackendError.outputIntegrityFailed(
                    output.id,
                    issues: integrity.issues
                )
            }
            verifiedOutputs.append(output)
        }
        guard Set(outputs) == Set(verifiedOutputs) else {
            throw CoreSpiceProcessBackendError.malformedProcessOutput(
                "The reported output identities do not match the requested output locations."
            )
        }
        return verifiedOutputs
    }

    private func referenceLog(
        at url: URL,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        do {
            return try referencer.reference(
                ArtifactLocator(
                    location: try ArtifactLocation(fileURL: url),
                    role: .output,
                    kind: .log,
                    format: format
                ),
                relativeTo: nil
            )
        } catch {
            throw CoreSpiceProcessBackendError.artifactReferenceFailed(
                error.localizedDescription
            )
        }
    }

    private static func defaultEnvironment() throws -> ExecutionEnvironmentFingerprint {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return try ExecutionEnvironmentFingerprint(
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            toolchain: "CoreSpice-CLI-0.1.0"
        )
    }
}
