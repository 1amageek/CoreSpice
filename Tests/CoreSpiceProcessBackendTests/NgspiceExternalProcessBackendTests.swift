import CircuiteFoundation
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
@testable import CoreSpiceProcessBackend
import Foundation
import Testing

private let liveNgspiceURL: URL? = [
    "/opt/homebrew/bin/ngspice",
    "/usr/local/bin/ngspice",
    "/usr/bin/ngspice",
].first(where: {
    FileManager.default.isExecutableFile(atPath: $0)
}).map {
    URL(fileURLWithPath: $0)
}

@Suite("Ngspice external process backend")
struct NgspiceExternalProcessBackendTests {
    @Test("Capability identifies executable and compact-model envelope")
    func capabilityIsExplicit() throws {
        let backend = try NgspiceExternalProcessBackend(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            toolVersion: "test",
            runRootURL: URL(fileURLWithPath: "/tmp/corespice-ngspice-tests")
        )

        #expect(backend.capability.simulator.identifier == "ngspice")
        #expect(backend.capability.executable.byteCount > 0)
        #expect(
            backend.capability.supports(
                mosModelLevel: 49,
                analysis: .operatingPoint
            )
        )
        #expect(
            backend.capability.supports(
                mosModelLevel: 54,
                analysis: .transient
            )
        )
        #expect(!backend.capability.controlsRandomSeed)
        #expect(!backend.capability.reportsExactConsumedInputs)
    }

    @Test("Declared inputs are verified and staged with relative include paths")
    func stagesDeclaredInputs() async throws {
        try await withTemporaryDirectory { directory in
            let sourceRoot = directory.appendingPathComponent(
                "source",
                isDirectory: true
            )
            let modelsDirectory = sourceRoot.appendingPathComponent(
                "models",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
            let deckURL = sourceRoot.appendingPathComponent("main.cir")
            let modelURL = modelsDirectory.appendingPathComponent("device.inc")
            try Data(
                """
                staged include
                .include models/device.inc
                .op
                .end

                """.utf8
            ).write(to: deckURL)
            try Data(".model nch nmos level=49\n".utf8).write(to: modelURL)
            let deck = try reference(
                deckURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let model = try reference(
                modelURL,
                role: .input,
                kind: .model,
                format: .spice
            )
            let runner = StagingProcessRunner()
            let runRoot = directory.appendingPathComponent("runs")
            let backend = try NgspiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                toolVersion: "test",
                runRootURL: runRoot,
                processRunner: runner,
                artifactLocator: try artifactLocator([
                    (deck, deckURL),
                    (model, modelURL),
                ])
            )

            let execution = try await backend.execute(
                CoreSpiceSimulationRequest(
                    inputs: [deck, model],
                    primaryInputID: deck.id
                )
            )

            #expect(execution.invocation.mode == .externalProcess)
            #expect(execution.artifacts.count == 3)
            #expect(await runner.sawPrimaryInput)
            #expect(await runner.sawRelativeInclude)
            for artifact in execution.artifacts {
                _ = try outputURL(for: artifact, under: runRoot)
            }
        }
    }

    @Test("Uncontrolled random seeds fail before launch")
    func rejectsRandomSeed() async throws {
        try await withTemporaryDirectory { directory in
            let deckURL = directory.appendingPathComponent("input.cir")
            try Data(".op\n.end\n".utf8).write(to: deckURL)
            let deck = try reference(
                deckURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let runner = StagingProcessRunner()
            let backend = try NgspiceExternalProcessBackend(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                toolVersion: "test",
                runRootURL: directory.appendingPathComponent("runs"),
                processRunner: runner,
                artifactLocator: try artifactLocator([(deck, deckURL)])
            )

            await #expect(
                throws: NgspiceExternalProcessBackendError.unsupportedRandomSeed
            ) {
                _ = try await backend.execute(
                    CoreSpiceSimulationRequest(
                        inputs: [deck],
                        primaryInputID: deck.id,
                        randomSeed: 1
                    )
                )
            }
            #expect(await runner.invocationCount == 0)
        }
    }

    @Test(
        "Installed ngspice executes the BSIM3 level 49 correlation fixture",
        .enabled(
            if: liveNgspiceURL != nil,
            "ngspice executable is not installed"
        )
    )
    func executesLiveBSIM3Fixture() async throws {
        let ngspiceURL = try #require(liveNgspiceURL)
        try await withTemporaryDirectory { directory in
            let fixtureURL = try #require(
                Bundle.module.url(
                    forResource: "bsim3-level49",
                    withExtension: "cir",
                    subdirectory: "Fixtures"
                )
            )
            let input = try reference(
                fixtureURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let runRoot = directory.appendingPathComponent("runs")
            let backend = try NgspiceExternalProcessBackend(
                executableURL: ngspiceURL,
                toolVersion: "46",
                runRootURL: runRoot,
                artifactLocator: try artifactLocator([(input, fixtureURL)])
            )

            let execution = try await backend.execute(
                CoreSpiceSimulationRequest(
                    inputs: [input],
                    primaryInputID: input.id
                )
            )

            let waveform = try #require(
                execution.artifacts.first {
                    $0.descriptor.kind == .waveform
                }
            )
            let waveformURL = try outputURL(for: waveform, under: runRoot)
            let rawText = try String(
                contentsOf: waveformURL,
                encoding: .utf8
            )
            let drainSupplyCurrent = try lastNumericLine(in: rawText)

            #expect(
                abs(drainSupplyCurrent - (-1.160437367488753e-5)) < 1e-12
            )
            #expect(
                execution.invocation.executable
                    == ngspiceURL.standardizedFileURL.resolvingSymlinksInPath().path
            )
            #expect(try containsOutput(named: "b3v33check.log", under: runRoot))
        }
    }

    @Test(
        "Installed ngspice executes the BSIM4 level 54 operating-region sweep",
        .enabled(
            if: liveNgspiceURL != nil,
            "ngspice executable is not installed"
        )
    )
    func executesLiveBSIM4Sweep() async throws {
        let ngspiceURL = try #require(liveNgspiceURL)
        try await withTemporaryDirectory { directory in
            let fixtureURL = try #require(
                Bundle.module.url(
                    forResource: "bsim4-level54-dc",
                    withExtension: "cir",
                    subdirectory: "Fixtures"
                )
            )
            let input = try reference(
                fixtureURL,
                role: .input,
                kind: .netlist,
                format: .spice
            )
            let runRoot = directory.appendingPathComponent("runs")
            let backend = try NgspiceExternalProcessBackend(
                executableURL: ngspiceURL,
                toolVersion: "46",
                runRootURL: runRoot,
                artifactLocator: try artifactLocator([(input, fixtureURL)])
            )

            let execution = try await backend.execute(
                CoreSpiceSimulationRequest(
                    inputs: [input],
                    primaryInputID: input.id
                )
            )
            let waveform = try #require(
                execution.artifacts.first {
                    $0.descriptor.kind == .waveform
                }
            )
            let waveformURL = try outputURL(for: waveform, under: runRoot)
            let rawText = try String(
                contentsOf: waveformURL,
                encoding: .utf8
            )
            let rows = try dcSweepRows(
                in: rawText,
                variableCount: 5,
                currentVariableIndex: 4
            )

            #expect(rows.count == 13)
            #expect(
                abs(rows[4].current - (-1.344953507037122e-11)) < 1e-16
            )
            #expect(
                abs(rows[8].current - (-5.246711515619466e-7)) < 1e-12
            )
            #expect(
                abs(rows[12].current - (-7.368345690040783e-5)) < 1e-10
            )
            let transconductance = -(
                rows[11].current - rows[10].current
            ) / (rows[11].sweep - rows[10].sweep)
            #expect(
                abs(transconductance - 2.392606349944368e-4) < 1e-9
            )
        }
    }

    private func reference(
        _ url: URL,
        role: ArtifactRole,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        let locator = try artifactLocator(
            url,
            role: role,
            kind: kind,
            format: format
        )
        return try LocalArtifactReferencer().reference(locator, relativeTo: nil)
    }

    private func artifactLocator(
        _ bindings: [(ArtifactReference, URL)]
    ) throws -> CoreSpiceArtifactLocatorRegistry {
        var locators: [ArtifactID: ArtifactLocator] = [:]
        for (reference, url) in bindings {
            locators[reference.id] = try artifactLocator(
                url,
                role: reference.descriptor.role,
                kind: reference.descriptor.kind,
                format: reference.descriptor.format
            )
        }
        return CoreSpiceArtifactLocatorRegistry(locatorsByArtifactID: locators)
    }

    private func artifactLocator(
        _ url: URL,
        role: ArtifactRole,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactLocator {
        ArtifactLocator(
            location: try ArtifactLocation(fileURL: url),
            role: role,
            kind: kind,
            format: format
        )
    }

    private func outputURL(
        for artifact: ArtifactReference,
        under root: URL
    ) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NgspiceTestError.missingOutputDirectory
        }
        let referencer = LocalArtifactReferencer()
        var matches: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let locator = try artifactLocator(
                url,
                role: artifact.descriptor.role,
                kind: artifact.descriptor.kind,
                format: artifact.descriptor.format
            )
            if try referencer.reference(locator, relativeTo: nil) == artifact {
                matches.append(url)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw NgspiceTestError.outputIdentityMismatch(artifact.id)
        }
        let locator = try artifactLocator(
            match,
            role: artifact.descriptor.role,
            kind: artifact.descriptor.kind,
            format: artifact.descriptor.format
        )
        guard LocalArtifactVerifier()
            .verify(artifact, at: locator, relativeTo: nil)
            .isVerified else {
            throw NgspiceTestError.outputIntegrityFailure(artifact.id)
        }
        return match
    }

    private func containsOutput(named name: String, under root: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NgspiceTestError.missingOutputDirectory
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return true
        }
        return false
    }

    private func lastNumericLine(in rawText: String) throws -> Double {
        for line in rawText.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let value = Double(trimmed) {
                return value
            }
        }
        throw NgspiceTestError.missingNumericValue
    }

    private func dcSweepRows(
        in rawText: String,
        variableCount: Int,
        currentVariableIndex: Int
    ) throws -> [(sweep: Double, current: Double)] {
        guard let valuesRange = rawText.range(of: "Values:") else {
            throw NgspiceTestError.missingValuesSection
        }
        let tokens = rawText[valuesRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }
        let valuesPerPoint = variableCount + 1
        guard tokens.count.isMultiple(of: valuesPerPoint),
              currentVariableIndex < variableCount else {
            throw NgspiceTestError.malformedValuesSection
        }
        return stride(
            from: 0,
            to: tokens.count,
            by: valuesPerPoint
        ).map { offset in
            (
                sweep: tokens[offset + 1],
                current: tokens[offset + currentVariableIndex + 1]
            )
        }
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
                Issue.record(
                    "Temporary directory cleanup failed: \(cleanupError)"
                )
            }
            throw error
        }
    }
}

private actor StagingProcessRunner: CoreSpiceProcessRunning {
    private(set) var invocationCount = 0
    private(set) var sawPrimaryInput = false
    private(set) var sawRelativeInclude = false

    func run(
        _ invocation: CoreSpiceProcessInvocation
    ) async throws -> CoreSpiceProcessOutput {
        invocationCount += 1
        guard let primaryPath = invocation.arguments.last,
              let rawArgument = invocation.arguments.first(where: {
                  $0.hasPrefix("--rawfile=")
              }) else {
            throw NgspiceTestError.missingProcessArgument
        }
        let primaryURL = URL(fileURLWithPath: primaryPath)
        let includeURL = primaryURL
            .deletingLastPathComponent()
            .appendingPathComponent("models/device.inc")
        sawPrimaryInput = FileManager.default.fileExists(
            atPath: primaryURL.path
        )
        sawRelativeInclude = FileManager.default.fileExists(
            atPath: includeURL.path
        )

        let rawPath = String(
            rawArgument.dropFirst("--rawfile=".count)
        )
        try Data("raw".utf8).write(
            to: URL(fileURLWithPath: rawPath)
        )
        try Data("ngspice stdout".utf8).write(
            to: invocation.standardOutputURL
        )
        try Data().write(to: invocation.standardErrorURL)
        return CoreSpiceProcessOutput(
            terminationStatus: 0,
            standardOutput: Data("ngspice stdout".utf8),
            standardError: Data()
        )
    }
}

private enum NgspiceTestError: Error {
    case missingNumericValue
    case missingOutputDirectory
    case missingProcessArgument
    case missingValuesSection
    case malformedValuesSection
    case outputIdentityMismatch(ArtifactID)
    case outputIntegrityFailure(ArtifactID)
}
