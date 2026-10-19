import CoreSpiceDevices
import CoreSpiceExporterCSV
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import Darwin
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("OSDI precision CLI original full schedules", .serialized)
struct OSDIPrecisionFullScheduleCLITests {
    @Test func fullBulkNLoaded() async throws { try await run("bsim-n-loaded-s4-transient") }
    @Test func fullBulkPReverseLoaded() async throws { try await run("bsim-p-reverse-loaded-s4-transient") }
    @Test func fullBulkPSelfheatLoaded() async throws { try await run("bsim-p-selfheat-loaded-s4-transient") }
    @Test func fullCMGNLoaded() async throws { try await run("cmg-n-loaded-s4-transient") }
    @Test func fullCMGPReverseLoaded() async throws { try await run("cmg-p-reverse-loaded-s4-transient") }
    @Test func fullCMGNSelfheatSeriesLoaded() async throws { try await run("cmg-n-selfheat-series-loaded-s4-transient") }
    @Test func fullIMGNLoaded() async throws { try await run("img-n-loaded-s4-transient") }
    @Test func fullIMGPReverse() async throws { try await run("img-p-reverse-s4-transient") }
    @Test func fullIMGNThermal() async throws { try await run("img-n-thermal-s4-transient") }
    @Test func fullSOINForward() async throws { try await run("soi-n-forward-s4-transient") }
    @Test func fullSOIPReverse() async throws { try await run("soi-p-reverse-s4-transient") }
    @Test func fullSOINSeriesThermal() async throws { try await run("soi-n-series-thermal-s4-transient") }

    private func manifest<Value: Decodable>(_ name: String, as type: Value.Type) throws -> Value {
        let path = try #require(ProcessInfo.processInfo.environment[name])
        return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func run(_ caseID: String) async throws {
        let analysis = try manifest("CORESPICE_OSDI_ANALYSIS_MANIFEST", as: OSDIAnalysisManifest.self)
        let precisionManifest = try manifest("CORESPICE_OSDI_PRECISION_MANIFEST", as: OSDIPrecisionManifest.self)
        let point = try #require(analysis.cases.first { $0.id == caseID })
        try #require(point.kind == "transient" && point.expectedOutcome == "passed")
        let device = try #require(point.input.circuit.devices.first)
        let originalSteps = try #require(point.input.analysis.steps)
        let first = try #require(originalSteps.first), last = try #require(originalSteps.last)
        try #require(last.timeSeconds > first.timeSeconds)
        let retained = ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_CLI_OUTPUT"]
        let parent = retained.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("full-" + caseID + "-" + UUID().uuidString)
        defer {
            if retained == nil {
                do {
                    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                } catch { Issue.record("Full schedule fixture cleanup failed: \(error)") }
            }
        }
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: device.library,
            manifest: precisionManifest, root: root, pointID: caseID, pilot: false)
        let source = try Data(contentsOf: fixture.deck)
        let originalCommand = ".tran \(first.timeStepSeconds) \(last.timeSeconds) 0 \(first.timeStepSeconds)"
        #expect(String(decoding: source, as: UTF8.self).contains(originalCommand))
        let saved = root.appendingPathComponent("batch.json")
        let started = ContinuousClock.now
        try await execute(["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
            "--csv", fixture.csv.path, "--paired-csv", fixture.pairedCSV.path, "--json"], output: saved)
        let maximumBytes = try #require(fixture.executionBudget["maximumEvidenceBytes"])
        let bytes = try LocalSPICESourceReader().read(at: saved.path, maximumByteCount: maximumBytes, maximumPageByteCount: 4096)
        let record = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: bytes)
        try #require(record.status == "succeeded")
        let execution = try #require(record.osdiExecution), precise = try #require(execution.precision)
        #expect(execution.analysis == "tran" && execution.schemaVersion == 2 && precise.schemaVersion == 1)
        #expect(execution.coordinates.first?.bitPattern == 0.0.bitPattern)
        #expect(execution.coordinates.last?.bitPattern == last.timeSeconds.bitPattern)
        #expect(precise.settings.transient.stopTime.bitPattern == last.timeSeconds.bitPattern)
        #expect(precise.settings.transient.maxTimeStep.bitPattern == first.timeStepSeconds.bitPattern)
        #expect(precise.settings.transient.useInitialConditions == (point.input.analysis.initialization == "uic"))
        #expect(execution.acceptedSteps.count == execution.coordinates.count - 1)
        #expect(precise.highBits == execution.real.map(\.bitPattern))
        #expect(precise.lowBits == precise.solutionLow.map(\.bitPattern))
        #expect(precise.coordinateBits == execution.coordinates.map(\.bitPattern))
        #expect(precise.equationPolicy.count == execution.rows.count)
        #expect(record.configurationIdentity == precise.configurationSHA256)
        let budget = try JSONDecoder().decode(CoreSpiceCLIPrecisionExecutionBudget.self,
            from: JSONSerialization.data(withJSONObject: fixture.executionBudget))
        #expect(precise.executionBudget == budget)
        let capture = try #require(precise.sources.captures.first)
        let unchangedSource = try Data(contentsOf: fixture.deck)
        #expect(precise.sources.captures.count == 1 && precise.sources.occurrences.count == 1)
        #expect(capture.bytes == source && unchangedSource == source)
        let cold = try #require(precise.coldModels.first)
        let model = try #require(precisionManifest.models.first { $0.id == device.library })
        #expect(precise.coldModels.count == 1 && cold.program.modelReference.digest.hexadecimalValue == model.sha256)
        #expect(cold.workerReference.digest.hexadecimalValue == precisionManifest.worker.sha256)
        #expect(cold.numericProfileSHA256 == precisionManifest.numericProfileSHA256)
        #expect(cold.program.semanticProfileSHA256 == precisionManifest.semanticProfileSHA256)
        #expect(cold.precisionBits == precisionManifest.precisionBits)
        for (index, step) in execution.acceptedSteps.enumerated() {
            let low = try #require(step.timeStepLowComponent)
            let interval = try CompensatedValue(high: execution.coordinates[index + 1])
                .subtracting(.init(high: execution.coordinates[index]))
            #expect(interval == (try CompensatedValue(high: step.timeStepSeconds, low: low)))
        }
        let reloadPath = root.appendingPathComponent("reloaded.json")
        try JSONEncoder().encode(record).write(to: reloadPath)
        let reloadBytes = try LocalSPICESourceReader().read(at: reloadPath.path,
            maximumByteCount: maximumBytes, maximumPageByteCount: 4096)
        #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: reloadBytes) == record)
        let pairBytes = try LocalSPICESourceReader().read(at: fixture.pairedCSV.path,
            maximumByteCount: maximumBytes, maximumPageByteCount: 4096)
        let limits = try CoreSpiceCLIPairedCSVCodec.Limits(maximumBytes: maximumBytes,
            maximumPoints: execution.coordinates.count, maximumColumns: execution.rows.count,
            maximumScalars: execution.real.count * 2 + execution.coordinates.count)
        let paired = try CoreSpiceCLIPairedCSVCodec.decode(pairBytes, limits: limits)
        #expect(paired.configurationSHA256 == precise.configurationSHA256)
        #expect(paired.sourceRowCount == execution.rows.count && paired.compiledRows == Array(execution.rows.indices))
        #expect(paired.times.map(\.bitPattern) == precise.coordinateBits)
        #expect(paired.high.map(\.bitPattern) == precise.highBits && paired.low.map(\.bitPattern) == precise.lowBits)
        try checkDisplay(execution, path: fixture.csv)
        print("Full precision CLI \(caseID): stop=\(last.timeSeconds), \(execution.acceptedSteps.count) accepted, \(execution.rows.count) rows, elapsed=\(started.duration(to: ContinuousClock.now)), saved=\(saved.path)")
    }

    private func checkDisplay(_ execution: CoreSpiceCLIOSDIExecutionRecord, path: URL) throws {
        let display = try CSVWaveformReader().read(contentsOfFile: path.path)
        #expect(display.pointCount == execution.coordinates.count && display.variableCount == execution.columns.count)
        for column in execution.columns.indices {
            #expect(display.variables[column].name == execution.columns[column].name)
            #expect(display.variables[column].unit.rawValue == execution.columns[column].unit)
            for point in execution.coordinates.indices {
                let high = execution.real[point * execution.columns.count + column]
                let value = try #require(display.realValue(variable: column, point: point))
                #expect(abs(value - high) <= max(abs(high) * 8e-15, Double.leastNonzeroMagnitude))
            }
        }
    }

    private func execute(_ arguments: [String], output: URL) async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        let timeoutText = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_CLI_TIMEOUT_SECONDS"])
        let timeout = try #require(UInt32(timeoutText))
        try #require(timeout > 0, "The caller must select a positive full-schedule command timeout")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "PATH", "TMPDIR", "SDKROOT", "TOOLCHAINS", "MallocNanoZone"].contains($0.key)
        }
        let errorPath = output.appendingPathExtension("stderr")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              FileManager.default.createFile(atPath: errorPath.path, contents: nil) else {
            throw OSDIDCManifest.Failure.invalidManifest
        }
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errorPath)
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            do { try stdout.close() } catch { Issue.record("Full schedule stdout close failed: \(error)") }
            do { try stderr.close() } catch { Issue.record("Full schedule stderr close failed: \(error)") }
        }
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(Int64(timeout)))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw CLIError.state("Full precision CLI exceeded the caller's \(timeout)-second command ceiling")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            try terminateAndReap(process)
            throw error
        }
        process.waitUntilExit()
        let errors = try String(contentsOf: errorPath, encoding: .utf8)
        try #require(process.terminationStatus == 0, "Full precision CLI exit \(process.terminationStatus): \(errors); output=\(output.path)")
    }

    private func terminateAndReap(_ process: Process) throws {
        if process.isRunning { process.terminate() }
        let gracefulDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        // Cleanup must run even when cancellation prevents further task suspension.
        while process.isRunning && ContinuousClock.now < gracefulDeadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock.now < killDeadline { usleep(10_000) }
        try #require(!process.isRunning, "Timed-out CLI child could not be stopped for reaping")
        process.waitUntilExit()
    }
}
