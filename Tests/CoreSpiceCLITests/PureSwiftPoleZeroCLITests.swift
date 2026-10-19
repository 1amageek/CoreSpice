@testable import CoreSpiceCLICore
import Foundation
import SignoffToolSupport
import Testing

@Suite("Pure Swift pole-zero preserved CLI integration", .timeLimit(.minutes(1)))
struct PureSwiftPoleZeroCLITests {
    @Test func preservedPreparedCLIColdReloadsCompleteAnalyticCandidateFromJSONAndCSV() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["CORESPICE_CLI_EXECUTABLE"]
            ?? environment["CORESPICE_OSDI_CLI_EXECUTABLE"], "Set the preserved production CLI executable explicitly")
        try #require(FileManager.default.isExecutableFile(atPath: executable), "Preserved CLI is unavailable: \(executable)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pure-swift-pz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Pole-zero fixture cleanup failed: \(error)") }
        }
        let deck = root.appendingPathComponent("lead-lag.cir")
        let csv = root.appendingPathComponent("candidate.csv")
        let json = root.appendingPathComponent("candidate.json")
        try """
        Pure Swift lead-lag
        V1 in 0 dc 1 ac 1
        R1 in out 1k
        C1 in out 1u
        R2 out 0 1k
        .pz in 0 out 0 vol pz
        .end

        """.write(to: deck, atomically: true, encoding: .utf8)
        let process = try await run(executable, arguments: ["prepared", deck.path, "--csv", csv.path, "--json"])
        try process.standardOutputData.write(to: json, options: .withoutOverwriting)
        try process.standardErrorData.write(to: root.appendingPathComponent("candidate.stderr"), options: .withoutOverwriting)
        try #require(process.exitCode == 0, "Prepared CLI failed: \(process.standardError)")

        let saved = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: json))
        try #require(saved.status == "succeeded" && saved.schemaVersion == 6 && saved.expectedCaseCount == 1)
        let cases = try #require(saved.cases)
        try #require(cases.count == 1)
        let selected = cases[0]
        #expect(selected.completion.schemaVersion == 7 && selected.completion.analysis == "pz")
        #expect(selected.completion.sourceInputIdentity == saved.sourceInputIdentity)
        let waveform = selected.waveform
        try checkAnalytic(waveform)
        try equalCandidate(waveform, try #require(selected.completion.savedWaveform))

        let roundtrip = root.appendingPathComponent("roundtrip.json")
        try JSONEncoder().encode(saved).write(to: roundtrip, options: .withoutOverwriting)
        let restored = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: roundtrip))
        let restoredCases = try #require(restored.cases)
        try #require(restoredCases.count == 1)
        #expect(restored.sourceInputIdentity == saved.sourceInputIdentity)
        #expect(restored.configurationIdentity == saved.configurationIdentity)
        #expect(restored.solverIdentity == saved.solverIdentity)
        #expect(restoredCases[0].selection == selected.selection)
        #expect(restoredCases[0].completion.configurationIdentity == selected.completion.configurationIdentity)
        try equalCandidate(waveform, restoredCases[0].waveform)
        try equalCandidate(waveform, try #require(restoredCases[0].completion.savedWaveform))

        let rows = try familyCSV(csv)
        try #require(rows.count == 3)
        let imaginary = try #require(waveform.imaginary)
        for (index, row) in rows.enumerated() {
            let descriptor = waveform.variables[index]
            #expect(row["case"] == String(selected.index))
            #expect(row["seed"] == String(selected.selection.seed))
            #expect(row["analysis"] == "pz" && row["sweep"] == waveform.sweep.name)
            #expect(row["variable"] == descriptor.name && row["unit"] == descriptor.unit.rawValue)
            #expect(row["phase"] == "result" && row["low"] == "")
            let temperature = try number(row, "temperature_celsius")
            let nominal = try number(row, "nominal_temperature_celsius")
            let coordinate = try number(row, "coordinate")
            let real = try number(row, "real")
            let imag = try number(row, "imaginary")
            #expect(temperature.bitPattern == selected.selection.temperatureCelsius.bitPattern)
            #expect(nominal.bitPattern == selected.selection.nominalTemperatureCelsius.bitPattern)
            #expect(coordinate.bitPattern == waveform.coordinates[0].bitPattern)
            #expect(real.bitPattern == waveform.real[index].bitPattern)
            #expect(imag.bitPattern == imaginary[index].bitPattern)
        }
    }

    private func checkAnalytic(_ waveform: CoreSpiceCLIPreparedWaveform) throws {
        // The feed-forward capacitor makes the finite zero independently observable.
        try #require(waveform.analysis.rawValue == "pz" && waveform.coordinates == [0])
        try #require(waveform.variables.map(\.name) == ["pole_0", "zero_0", "dc_gain"])
        try #require(waveform.real.count == 3)
        let imaginary = try #require(waveform.imaginary)
        try #require(imaginary.count == 3)
        #expect(abs(waveform.real[0] + 2000) < 1e-6)
        #expect(abs(waveform.real[1] + 1000) < 1e-6)
        #expect(abs(waveform.real[2] - 0.5) < 1e-12)
        #expect(imaginary.allSatisfy { abs($0) < 1e-9 })
        #expect(waveform.variables.map { $0.unit.rawValue } == ["rad/s", "rad/s", ""])
    }

    private func equalCandidate(_ expected: CoreSpiceCLIPreparedWaveform,
                                _ actual: CoreSpiceCLIPreparedWaveform) throws {
        #expect(actual.analysis == expected.analysis && actual.options == expected.options)
        #expect(actual.sweep == expected.sweep && actual.variables == expected.variables)
        #expect(actual.coordinates.map(\.bitPattern) == expected.coordinates.map(\.bitPattern))
        #expect(actual.real.map(\.bitPattern) == expected.real.map(\.bitPattern))
        let actualImaginary = try #require(actual.imaginary)
        let expectedImaginary = try #require(expected.imaginary)
        #expect(actualImaginary.map(\.bitPattern) == expectedImaginary.map(\.bitPattern))
    }

    private func number(_ row: [String: String], _ key: String) throws -> Double {
        let text = try #require(row[key])
        return try #require(Double(text))
    }

    private func familyCSV(_ path: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: path, encoding: .utf8)
        var records: [[String]] = [], fields: [String] = [], field = "", quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index], next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                quoted.toggle()
            } else if character == "," && !quoted { fields.append(field); field = "" }
            else if character == "\n" && !quoted {
                fields.append(field); records.append(fields); fields = []; field = ""
            } else { field.append(character) }
            index = next
        }
        try #require(!quoted && fields.isEmpty && field.isEmpty)
        let header = try #require(records.first)
        try #require(header == ["case", "temperature_celsius", "nominal_temperature_celsius", "seed", "analysis", "sweep", "coordinate", "variable", "real", "imaginary", "unit", "phase", "low"])
        return try records.dropFirst().map { fields in
            try #require(fields.count == header.count)
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }

    private func run(_ executable: String, arguments: [String]) async throws -> TimedProcessResult {
        let runner = TimedProcessRunner(timeoutSeconds: 30, maximumOutputByteCount: 1024 * 1024, cleanupTimeoutSeconds: 2)
        do {
            return try await runner.run(executableURL: URL(fileURLWithPath: executable), arguments: arguments,
                control: TimedProcessControl())
        } catch TimedProcessError.executionFailed(let original) {
            guard let handle = original.cleanupHandle else { throw TimedProcessError.executionFailed(original) }
            do { try await handle.close(timeoutSeconds: 2) }
            catch {
                throw TimedProcessError.executionFailed(TimedProcessFailure(executablePath: original.executablePath,
                    cause: original.cause, standardOutputData: original.standardOutputData,
                    standardErrorData: original.standardErrorData,
                    cleanupIssue: "\(original.cleanupIssue ?? "pending"); retry: \(error)", cleanupHandle: handle))
            }
            throw TimedProcessError.executionFailed(TimedProcessFailure(executablePath: original.executablePath,
                cause: original.cause, standardOutputData: original.standardOutputData,
                standardErrorData: original.standardErrorData))
        }
    }
}
