import Foundation
import Testing

/// Runs the supported-model numerical regression corpus in CI without
/// requiring ngspice. The committed fixture is regression evidence only; use
/// a live-oracle run to emit independent correlation evidence.
@Suite("Numerical regression")
struct NumericalRegressionTests {
    private enum ExecutableDiscoveryError: Error, CustomStringConvertible {
        case corespiceNotFound(searchedPaths: [String])

        var description: String {
            switch self {
            case let .corespiceNotFound(searchedPaths):
                return "The corespice executable was not found in the current test build products: "
                    + searchedPaths.joined(separator: ", ")
            }
        }
    }

    private struct CorpusManifest: Decodable {
        struct Case: Decodable {
            let id: String
            let name: String
        }

        let cases: [Case]
    }

    private struct RunManifest: Decodable {
        struct Summary: Decodable {
            let total: Int
            let passed: Int
            let failed: Int
        }

        let schemaVersion: Int
        let runType: String
        let qualificationAuthority: String
        let summary: Summary
    }

    private struct CorrelationReport: Decodable {
        struct Result: Decodable {
            struct Artifact: Decodable {
                let role: String
                let path: String
                let sha256: String
                let byteCount: Int
            }

            let caseID: String
            let name: String
            let passed: Bool
            let detail: String
            let inputSHA256: String
            let artifacts: [Artifact]
        }

        let schemaVersion: Int
        let comparisonSource: String
        let evidenceClass: String
        let results: [Result]
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func corespiceExecutable(packageRoot: URL) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var directories: [URL] = []

        if let builtProductsDirectory = environment["BUILT_PRODUCTS_DIR"] {
            directories.append(URL(fileURLWithPath: builtProductsDirectory, isDirectory: true))
        }

        for variable in ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
            if let paths = environment[variable] {
                directories.append(contentsOf: paths.split(separator: ":").map {
                    URL(fileURLWithPath: String($0), isDirectory: true)
                })
            }
        }

        directories.append(packageRoot.appendingPathComponent(".build/debug", isDirectory: true))

        var ancestor = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<8 {
            directories.append(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor {
                break
            }
            ancestor = parent
        }

        var searchedPaths: [String] = []
        var visitedDirectories: Set<String> = []
        for directory in directories where visitedDirectories.insert(directory.path).inserted {
            let candidate = directory.appendingPathComponent("corespice")
            searchedPaths.append(candidate.path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw ExecutableDiscoveryError.corespiceNotFound(searchedPaths: searchedPaths)
    }

    private func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [launchPath] + arguments
        process.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    @Test("Regression corpus passes without a live oracle", .timeLimit(.minutes(5)))
    func regressionCorpusPasses() throws {
        let root = packageRoot()
        let corespice = try corespiceExecutable(packageRoot: root)
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corespice-regression-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: artifactDirectory.path) {
                do {
                    try FileManager.default.removeItem(at: artifactDirectory)
                } catch {
                    Issue.record("Failed to remove numerical regression artifacts: \(error)")
                }
            }
        }

        let runner = root.appendingPathComponent("validation/gate.py").path
        let (status, output) = try run(
            "python3",
            [
                runner,
                "--corespice", corespice.path,
                "--comparison-source", "regression-fixture",
                "--artifact-dir", artifactDirectory.path,
            ],
            currentDirectory: root
        )
        #expect(status == 0, "Numerical regression did not pass:\n\(output)")

        let manifestURL = artifactDirectory.appendingPathComponent("manifest.json")
        let reportURL = artifactDirectory.appendingPathComponent("oracle-comparison.json")
        let corpusURL = root.appendingPathComponent("validation/corpus-manifest.json")
        let corpus = try JSONDecoder().decode(
            CorpusManifest.self,
            from: Data(contentsOf: corpusURL)
        )
        let manifest = try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let report = try JSONDecoder().decode(
            CorrelationReport.self,
            from: Data(contentsOf: reportURL)
        )

        #expect(manifest.schemaVersion == 2)
        #expect(manifest.runType == "regression-validation")
        #expect(manifest.qualificationAuthority == "ToolQualification")
        #expect(manifest.summary.total == corpus.cases.count)
        #expect(manifest.summary.passed == corpus.cases.count)
        #expect(manifest.summary.failed == 0)
        #expect(report.schemaVersion == 2)
        #expect(report.comparisonSource == "regression-fixture")
        #expect(report.evidenceClass == "regression")
        #expect(Set(report.results.map(\.caseID)) == Set(corpus.cases.map(\.id)))
        #expect(Set(report.results.map(\.name)) == Set(corpus.cases.map(\.name)))
        #expect(report.results.allSatisfy { $0.passed })
        #expect(report.results.allSatisfy { !$0.detail.isEmpty })
        #expect(report.results.allSatisfy { $0.inputSHA256.count == 64 })
        #expect(report.results.allSatisfy { result in
            result.artifacts.contains { artifact in
                artifact.role == "input"
                    && artifact.sha256.count == 64
                    && artifact.byteCount > 0
                    && FileManager.default.fileExists(
                        atPath: artifactDirectory.appendingPathComponent(artifact.path).path
                    )
            }
        })
    }
}
