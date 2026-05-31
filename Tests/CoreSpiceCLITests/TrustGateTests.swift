import Testing
import Foundation

/// Runs the full numerical trust gate (validation/gate.py) in golden mode as part
/// of `swift test`, so the corpus is exercised in CI without ngspice installed.
/// The golden references (validation/golden.json) are committed; regenerate them
/// with `python3 validation/gate.py --update-golden` when the reference simulator
/// or a circuit changes.
@Suite("Numerical trust gate (golden)")
struct TrustGateTests {

    private func packageRoot() -> URL {
        // .../Tests/CoreSpiceCLITests/TrustGateTests.swift -> package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func run(_ launchPath: String, _ args: [String], cwd: URL? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [launchPath] + args
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    @Test("gate.py passes in golden mode (no ngspice)", .timeLimit(.minutes(5)))
    func trustGatePasses() throws {
        let root = packageRoot()
        let corespice = root.appendingPathComponent(".build/debug/corespice")
        let artifactDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corespice-trust-gate-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: artifactDir.path) {
                do {
                    try FileManager.default.removeItem(at: artifactDir)
                } catch {
                    Issue.record("failed to remove trust gate artifact directory: \(error)")
                }
            }
        }

        // Ensure the CLI binary the gate drives is built.
        if !FileManager.default.fileExists(atPath: corespice.path) {
            let (status, output) = try run("swift", ["build", "--product", "corespice"], cwd: root)
            try #require(status == 0, "failed to build corespice:\n\(output)")
        }

        let gate = root.appendingPathComponent("validation/gate.py").path
        let (status, output) = try run(
            "python3",
            [gate, "--corespice", corespice.path, "--artifact-dir", artifactDir.path],
            cwd: root
        )
        #expect(status == 0, "trust gate did not pass:\n\(output)")

        let manifest = artifactDir.appendingPathComponent("manifest.json")
        let comparison = artifactDir.appendingPathComponent("oracle-comparison.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: comparison.path))
    }
}
