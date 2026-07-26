import CircuiteFoundation
import CoreSpice
import Foundation

/// An explicit ngspice adapter for compact-model execution outside the native
/// CoreSpice device envelope.
public struct NgspiceExternalProcessBackend: CoreSpiceExternalSimulatorBackend {
    public let capability: CoreSpiceExternalSimulatorCapability

    private struct VerifiedInput {
        let reference: ArtifactReference
        let sourceURL: URL
    }

    private let executableURL: URL
    private let runRootURL: URL
    private let processRunner: any CoreSpiceProcessRunning
    private let verifier: any ArtifactVerifying
    private let referencer: any ArtifactReferencing
    private let environment: ExecutionEnvironmentFingerprint

    public init(
        executableURL: URL,
        toolVersion: String,
        runRootURL: URL,
        processRunner: any CoreSpiceProcessRunning = FoundationCoreSpiceProcessRunner(),
        verifier: any ArtifactVerifying = LocalArtifactVerifier(),
        referencer: any ArtifactReferencing = LocalArtifactReferencer(),
        environment: ExecutionEnvironmentFingerprint? = nil
    ) throws {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw NgspiceExternalProcessBackendError.invalidExecutable(
                executableURL.path
            )
        }
        guard runRootURL.isFileURL, runRootURL.path.hasPrefix("/") else {
            throw NgspiceExternalProcessBackendError.invalidRunRoot(
                runRootURL.absoluteString
            )
        }

        let standardizedExecutable = executableURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let simulator = try ProducerIdentity(
            kind: .tool,
            identifier: "ngspice",
            version: toolVersion
        )
        let executableReference: ArtifactReference
        do {
            executableReference = try referencer.reference(
                ArtifactLocator(
                    location: try ArtifactLocation(
                        fileURL: standardizedExecutable
                    ),
                    role: .input,
                    kind: try ArtifactKind(rawValue: "executable"),
                    format: .unknown
                ),
                relativeTo: nil,
                producer: simulator
            )
        } catch {
            throw NgspiceExternalProcessBackendError.artifactReferenceFailed(
                error.localizedDescription
            )
        }

        self.executableURL = standardizedExecutable
        self.runRootURL = runRootURL.standardizedFileURL
        self.processRunner = processRunner
        self.verifier = verifier
        self.referencer = referencer
        self.environment = try environment ?? Self.defaultEnvironment(
            toolVersion: toolVersion,
            executableDigest: executableReference.digest
        )
        self.capability = CoreSpiceExternalSimulatorCapability(
            simulator: simulator,
            executable: executableReference,
            supportedMOSModelLevels: [49, 54],
            supportedAnalyses: [
                .operatingPoint,
                .dc,
                .ac,
                .transient,
                .noise,
            ],
            controlsRandomSeed: false,
            reportsExactConsumedInputs: false
        )
    }

    public func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationExecution {
        try Task.checkCancellation()
        guard request.randomSeed == nil else {
            throw NgspiceExternalProcessBackendError.unsupportedRandomSeed
        }

        let verifiedInputs = try verifyInputs(request.inputs)
        let primaryInput = try primaryInputReference(for: request)
        guard verifiedInputs.contains(where: {
            $0.reference.id == primaryInput.id
        }) else {
            throw NgspiceExternalProcessBackendError.primaryInputNotFound(
                primaryInput.id
            )
        }

        let runDirectoryURL = runRootURL.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        let stagedInputs = try stage(
            verifiedInputs,
            in: runDirectoryURL.appendingPathComponent(
                "inputs",
                isDirectory: true
            )
        )
        guard let primaryInputURL = stagedInputs[primaryInput.id] else {
            throw NgspiceExternalProcessBackendError.primaryInputNotFound(
                primaryInput.id
            )
        }

        let rawURL = runDirectoryURL.appendingPathComponent("waveform.raw")
        let standardOutputURL = runDirectoryURL.appendingPathComponent(
            "stdout.log"
        )
        let standardErrorURL = runDirectoryURL.appendingPathComponent(
            "stderr.log"
        )
        let arguments = [
            "--no-spiceinit",
            "--batch",
            "--rawfile=\(rawURL.path)",
            primaryInputURL.path,
        ]
        let invocation = try ExecutionInvocation.externalProcess(
            executable: executableURL.path,
            arguments: arguments,
            workingDirectory: primaryInputURL
                .deletingLastPathComponent()
                .path
        )
        let startedAt = Date()
        let output = try await processRunner.run(
            CoreSpiceProcessInvocation(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectoryURL: primaryInputURL.deletingLastPathComponent(),
                standardOutputURL: standardOutputURL,
                standardErrorURL: standardErrorURL
            )
        )
        let completedAt = Date()

        guard output.terminationStatus == 0 else {
            let standardError = String(
                decoding: output.standardError,
                as: UTF8.self
            )
            let standardOutput = String(
                decoding: output.standardOutput,
                as: UTF8.self
            )
            let message = standardError.isEmpty
                ? standardOutput
                : standardError
            throw NgspiceExternalProcessBackendError.processFailed(
                status: output.terminationStatus,
                message: message.isEmpty
                    ? "No process diagnostics were emitted."
                    : message
            )
        }
        try verifyStagedInputsUnchanged(
            stagedInputs,
            declaredInputs: verifiedInputs
        )
        guard fileManagerHasNonEmptyFile(at: rawURL) else {
            throw NgspiceExternalProcessBackendError.missingWaveformOutput(
                rawURL.path
            )
        }

        var artifacts = try [
            referenceOutput(
                at: rawURL,
                kind: .waveform,
                format: .raw
            ),
            referenceOutput(
                at: standardOutputURL,
                kind: .log,
                format: .text
            ),
            referenceOutput(
                at: standardErrorURL,
                kind: .log,
                format: .text
            ),
        ]
        artifacts += try referenceAncillaryOutputs(
            in: runDirectoryURL,
            excluding: Set(
                stagedInputs.values.map(\.standardizedFileURL.path)
                    + [
                        rawURL.standardizedFileURL.path,
                        standardOutputURL.standardizedFileURL.path,
                        standardErrorURL.standardizedFileURL.path,
                    ]
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
    ) throws -> [VerifiedInput] {
        try inputs.map { input in
            let integrity = verifier.verify(input, relativeTo: nil)
            guard integrity.isVerified else {
                throw NgspiceExternalProcessBackendError.inputIntegrityFailed(
                    input.id,
                    issues: integrity.issues
                )
            }
            do {
                return VerifiedInput(
                    reference: input,
                    sourceURL: try input.locator.location.resolvedFileURL()
                        .resolvingSymlinksInPath()
                )
            } catch {
                throw NgspiceExternalProcessBackendError.inputLocationInvalid(
                    input.id,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func primaryInputReference(
        for request: CoreSpiceSimulationRequest
    ) throws -> ArtifactReference {
        if let primaryInputID = request.primaryInputID {
            guard let input = request.inputs.first(where: {
                $0.id == primaryInputID
            }) else {
                throw NgspiceExternalProcessBackendError.primaryInputNotFound(
                    primaryInputID
                )
            }
            return input
        }
        let candidates = request.inputs.filter {
            $0.locator.kind == .netlist && $0.locator.format == .spice
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw NgspiceExternalProcessBackendError.ambiguousPrimaryInput(
                candidateCount: candidates.count
            )
        }
        return candidate
    }

    private func stage(
        _ inputs: [VerifiedInput],
        in stagingRootURL: URL
    ) throws -> [ArtifactID: URL] {
        guard !inputs.isEmpty else {
            return [:]
        }
        let sourceRoot = commonParentDirectory(
            inputs.map(\.sourceURL)
        )
        let fileManager = FileManager.default
        var stagedInputs: [ArtifactID: URL] = [:]
        do {
            try fileManager.createDirectory(
                at: stagingRootURL,
                withIntermediateDirectories: true
            )
            for input in inputs {
                let relativeComponents = input.sourceURL.pathComponents
                    .dropFirst(sourceRoot.pathComponents.count)
                guard !relativeComponents.isEmpty,
                      !relativeComponents.contains("..") else {
                    throw NgspiceExternalProcessBackendError.inputStagingFailed(
                        "Input \(input.reference.id) is outside the staging root."
                    )
                }
                let destination = relativeComponents.reduce(
                    stagingRootURL
                ) { partial, component in
                    partial.appendingPathComponent(component)
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // The copy is required to isolate execution to declared inputs
                // while preserving relative include paths. FileManager may use
                // a filesystem clone, avoiding a full byte copy on APFS.
                try fileManager.copyItem(
                    at: input.sourceURL,
                    to: destination
                )
                let stagedReference = try referencer.reference(
                    ArtifactLocator(
                        location: try ArtifactLocation(fileURL: destination),
                        role: .input,
                        kind: input.reference.locator.kind,
                        format: input.reference.locator.format
                    ),
                    relativeTo: nil,
                    producer: input.reference.producer
                )
                guard stagedReference.digest == input.reference.digest,
                      stagedReference.byteCount == input.reference.byteCount else {
                    throw NgspiceExternalProcessBackendError.inputStagingFailed(
                        "Staged input \(input.reference.id) changed during copy."
                    )
                }
                stagedInputs[input.reference.id] = destination
            }
        } catch let error as NgspiceExternalProcessBackendError {
            throw error
        } catch {
            throw NgspiceExternalProcessBackendError.inputStagingFailed(
                error.localizedDescription
            )
        }
        return stagedInputs
    }

    private func commonParentDirectory(_ urls: [URL]) -> URL {
        var common = urls[0]
            .deletingLastPathComponent()
            .pathComponents
        for url in urls.dropFirst() {
            let components = url
                .deletingLastPathComponent()
                .pathComponents
            common = Array(
                zip(common, components)
                    .prefix { pair in pair.0 == pair.1 }
                    .map { $0.0 }
            )
        }
        return URL(
            fileURLWithPath: NSString.path(
                withComponents: common
            ),
            isDirectory: true
        )
    }

    private func verifyStagedInputsUnchanged(
        _ stagedInputs: [ArtifactID: URL],
        declaredInputs: [VerifiedInput]
    ) throws {
        for input in declaredInputs {
            guard let stagedURL = stagedInputs[input.reference.id] else {
                throw NgspiceExternalProcessBackendError.primaryInputNotFound(
                    input.reference.id
                )
            }
            do {
                let stagedReference = try referencer.reference(
                    ArtifactLocator(
                        location: try ArtifactLocation(fileURL: stagedURL),
                        role: .input,
                        kind: input.reference.locator.kind,
                        format: input.reference.locator.format
                    ),
                    relativeTo: nil,
                    producer: input.reference.producer
                )
                guard stagedReference.digest == input.reference.digest,
                      stagedReference.byteCount == input.reference.byteCount else {
                    throw NgspiceExternalProcessBackendError.inputStagingFailed(
                        "Ngspice modified staged input \(input.reference.id)."
                    )
                }
            } catch let error as NgspiceExternalProcessBackendError {
                throw error
            } catch {
                throw NgspiceExternalProcessBackendError.inputStagingFailed(
                    error.localizedDescription
                )
            }
        }
    }

    private func referenceAncillaryOutputs(
        in runDirectoryURL: URL,
        excluding excludedPaths: Set<String>
    ) throws -> [ArtifactReference] {
        guard let enumerator = FileManager.default.enumerator(
            at: runDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NgspiceExternalProcessBackendError.artifactReferenceFailed(
                "The ngspice run directory could not be enumerated."
            )
        }

        var outputURLs: [URL] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isRegularFileKey]
                )
            } catch {
                throw NgspiceExternalProcessBackendError.artifactReferenceFailed(
                    error.localizedDescription
                )
            }
            guard values.isRegularFile == true,
                  !excludedPaths.contains(url.standardizedFileURL.path) else {
                continue
            }
            outputURLs.append(url)
        }

        return try outputURLs
            .sorted { $0.path < $1.path }
            .map { url in
                let isTextLog = url.pathExtension.lowercased() == "log"
                return try referenceOutput(
                    at: url,
                    kind: isTextLog ? .log : .other,
                    format: isTextLog ? .text : .unknown
                )
            }
    }

    private func fileManagerHasNonEmptyFile(at url: URL) -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
        } catch {
            return false
        }
        guard
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.uint64Value > 0
    }

    private func referenceOutput(
        at url: URL,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        do {
            return try referencer.reference(
                ArtifactLocator(
                    location: try ArtifactLocation(fileURL: url),
                    role: .output,
                    kind: kind,
                    format: format
                ),
                relativeTo: nil,
                producer: capability.simulator
            )
        } catch {
            throw NgspiceExternalProcessBackendError.artifactReferenceFailed(
                error.localizedDescription
            )
        }
    }

    private static func defaultEnvironment(
        toolVersion: String,
        executableDigest: ContentDigest
    ) throws -> ExecutionEnvironmentFingerprint {
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
            toolchain: "ngspice-\(toolVersion)",
            environmentDigest: executableDigest
        )
    }
}
