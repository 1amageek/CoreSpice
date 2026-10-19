import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import Foundation
import Darwin
import Testing
@testable import CoreSpiceCLICore

@Suite("OSDI precision CLI complete evidence", .serialized, .timeLimit(.minutes(5)))
struct OSDIPrecisionCLIExecutionTests {
    private func manifest() throws -> OSDIPrecisionManifest {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_MANIFEST"])
        return try JSONDecoder().decode(OSDIPrecisionManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    private func root(_ name: String) throws -> URL {
        if let directory = ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_CLI_OUTPUT"] {
            return URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + UUID().uuidString)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("osdi-precision-cli-" + name + "-" + UUID().uuidString)
    }
    private func cleanup(_ root: URL) throws {
        if ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_CLI_OUTPUT"] == nil { try FileManager.default.removeItem(at: root) }
    }
    private func process(_ arguments: [String], output: URL) async throws -> Data {
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "PATH", "TMPDIR", "SDKROOT", "TOOLCHAINS", "MallocNanoZone"].contains($0.key) }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw OSDIDCManifest.Failure.invalidManifest }
        let errorPath = output.appendingPathExtension("stderr")
        guard FileManager.default.createFile(atPath: errorPath.path, contents: nil) else { throw OSDIDCManifest.Failure.invalidManifest }
        let handle = try FileHandle(forWritingTo: output), errors = try FileHandle(forWritingTo: errorPath)
        defer { do { try handle.close(); try errors.close() } catch { Issue.record("CLI output handle cleanup failed: \(error)") } }
        process.standardOutput = handle; process.standardError = errors
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                process.terminate()
                let stop = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning && ContinuousClock.now < stop { try await Task.sleep(for: .milliseconds(10)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CLIError.state("Bounded precision CLI command exceeded 120 seconds")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bytes = try LocalSPICESourceReader().read(at: output.path, maximumByteCount: 128 * 1024 * 1024, maximumPageByteCount: 4096)
        let errorText = try String(contentsOf: errorPath, encoding: .utf8)
        let failure = process.terminationStatus == 0 ? "" : String(decoding: bytes, as: UTF8.self)
        try #require(process.terminationStatus == 0, "\(arguments.first ?? "CLI"): \(failure) \(errorText)")
        return bytes
    }
    private func check(_ execution: CoreSpiceCLIOSDIExecutionRecord, fixture: OSDIPrecisionCLIFixture,
                       manifest: OSDIPrecisionManifest, modelID: String, pairedPath: URL? = nil, csvPath: URL? = nil) throws {
        let precision = try #require(execution.precision), model = try #require(manifest.models.first { $0.id == modelID })
        #expect(execution.schemaVersion == 2 && precision.schemaVersion == 1)
        #expect(precision.coldModels.count == 1 && precision.equationPolicy.count == execution.rows.count)
        let cold = try #require(precision.coldModels.first)
        #expect(cold.program.modelReference.digest.hexadecimalValue == model.sha256)
        #expect(cold.workerReference.digest.hexadecimalValue == manifest.worker.sha256)
        #expect(cold.numericProfileSHA256 == manifest.numericProfileSHA256 && cold.program.semanticProfileSHA256 == manifest.semanticProfileSHA256)
        #expect(cold.precisionBits == manifest.precisionBits)
        #expect(precision.sources.captures.count == 1 && precision.sources.occurrences.count == 1)
        let capture = try #require(precision.sources.captures.first)
        #expect(capture.bytes == (try Data(contentsOf: fixture.deck)))
        #expect(precision.highBits == execution.real.map(\.bitPattern) && precision.lowBits == precision.solutionLow.map(\.bitPattern))
        #expect(precision.coordinateBits == execution.coordinates.map(\.bitPattern))
        for (index, step) in execution.acceptedSteps.enumerated() {
            let low = try #require(step.timeStepLowComponent)
            let exact = try CompensatedValue(high: step.timeSeconds).subtracting(.init(high: execution.coordinates[index]))
            #expect(exact == (try CompensatedValue(high: step.timeStepSeconds, low: low)))
        }
        let bytes = try LocalSPICESourceReader().read(at: (pairedPath ?? fixture.pairedCSV).path, maximumByteCount: precision.executionBudget.maximumEvidenceBytes, maximumPageByteCount: 4096)
        let limits = try CoreSpiceCLIPairedCSVCodec.Limits(maximumBytes: precision.executionBudget.maximumEvidenceBytes,
            maximumPoints: 1_000_000, maximumColumns: execution.rows.count, maximumScalars: 3_000_000)
        let decoded = try CoreSpiceCLIPairedCSVCodec.decode(bytes, limits: limits)
        let expected = try execution.pairedCSVRecord()
        #expect(decoded.configurationSHA256 == precision.configurationSHA256 && decoded.compiledRows == expected.compiledRows)
        #expect(decoded.high.map(\.bitPattern) == expected.high.map(\.bitPattern) && decoded.low.map(\.bitPattern) == expected.low.map(\.bitPattern))
        #expect(decoded.times.map(\.bitPattern) == expected.times.map(\.bitPattern))
        #expect(FileManager.default.fileExists(atPath: (csvPath ?? fixture.csv).path))
    }
    private func family(_ id: String) async throws {
        let manifest = try manifest(), root = try root(id)
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: id, manifest: manifest, root: root)
        defer { do { try cleanup(root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let batchPath = root.appendingPathComponent("batch.json")
        let batchBytes = try await process(["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
            "--csv", fixture.csv.path, "--paired-csv", fixture.pairedCSV.path, "--json"], output: batchPath)
        let batch = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: batchBytes)
        let execution = try #require(batch.osdiExecution)
        try check(execution, fixture: fixture, manifest: manifest, modelID: id)
        let preparedCSV = root.appendingPathComponent("prepared.csv"), preparedPaired = root.appendingPathComponent("prepared-paired.csv")
        let preparedBytes = try await process(["prepared", fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
            "--csv", preparedCSV.path, "--paired-csv", preparedPaired.path, "--json"], output: root.appendingPathComponent("prepared.json"))
        let prepared = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: preparedBytes)
        let repeated = try #require(prepared.osdiExecution)
        try check(repeated, fixture: fixture, manifest: manifest, modelID: id, pairedPath: preparedPaired, csvPath: preparedCSV)
        #expect(batch.configurationIdentity == prepared.configurationIdentity && batch.sourceInputIdentity == prepared.sourceInputIdentity)
        #expect(execution == repeated && batch.osdiModels == prepared.osdiModels)
        let saved = try JSONEncoder().encode(batch)
        #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: saved) == batch)
    }
    @Test func bulkActualBatchPreparedAndExactPersistence() async throws { try await family("bsim") }
    @Test func cmgActualBatchPreparedAndExactPersistence() async throws { try await family("cmg") }
    @Test func imgActualBatchPreparedAndExactPersistence() async throws { try await family("img") }
    @Test func soiActualBatchPreparedAndExactPersistence() async throws { try await family("soi") }
    @Test func contextActualBatchPreparedAndExactPersistence() async throws { try await family("context") }

    private func proveSingleRunBudgetPreservesPreviousCompletion(_ fixture: OSDIPrecisionCLIFixture) async throws {
        let completed = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path]).executeWithRecord()
        let catalog = try CoreSpiceCLIOSDICatalog.load(path: fixture.catalog.path)
        var session = Session(policy: try .developerV1().applying(catalog.executionBudget))
        try session.adoptPrecision(output: completed.output, completed: completed.record, catalog: catalog)
        let previous = try #require(session.completedOSDIExecution)
        let analysis = try session.requiredDefaultRunnableAnalysis()
        do {
            _ = try await session.runParsed(analysis)
            Issue.record("Single-invocation caller ceiling unexpectedly admitted retained old/new coexistence")
        } catch let error as SPICENativePreparationError {
            guard case .resource(let cause) = error, let resource = cause as? SPICESimulationResources.ResourceError,
                  case .storageLimit = resource else { throw error }
            #expect(session.isLoaded && session.completedOSDIExecution == previous)
            #expect(session.lastWaveform?.pointCount == previous.coordinates.count)
        }
    }

    @Test func compoundProjectionStrictReloadFreshRerunAndCancelledOutput() async throws {
        var stage = "fixture"
        do {
        let manifest = try manifest(), root = try root("compound")
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: "compound", manifest: manifest, root: root)
        defer { do { try cleanup(root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let original = try String(contentsOf: fixture.deck, encoding: .utf8)
        let source = original.replacingOccurrences(of: ".end\n", with: "VREF q 0 0.25\nRREF q 0 100\n.save I(VREF) V(p)\n.end\n")
        try source.write(to: fixture.deck, atomically: true, encoding: .utf8)
        stage = "single-budget-retained-refusal"
        try await proveSingleRunBudgetPreservesPreviousCompletion(fixture)
        // The original caller ceiling was measured insufficient for preserved old/new
        // observations. This test explicitly selects two invocation envelopes.
        var callerCatalog = fixture.catalogJSON
        var callerBudget = try #require(callerCatalog["executionBudget"] as? [String: Any])
        let originalLive = try #require(fixture.executionBudget["maximumLiveOwnedBytes"])
        let (coexistenceLive, overflow) = originalLive.multipliedReportingOverflow(by: 2)
        try #require(!overflow)
        callerBudget["maximumLiveOwnedBytes"] = coexistenceLive
        callerCatalog["executionBudget"] = callerBudget
        try JSONSerialization.data(withJSONObject: callerCatalog).write(to: fixture.catalog)
        let command = CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
            "--csv", fixture.csv.path, "--paired-csv", fixture.pairedCSV.path])
        stage = "initial-prepared-command"
        var completed: (output: SPICENativeSimulationOutput, record: CoreSpiceCLIPreparedRunRecord, serializedPrecisionJSON: String?, serializationReservation: SPICESourceStorageReservation?)? = try await command.executeWithRecord()
        let record = try #require(completed?.record), execution = try #require(record.osdiExecution)
        let precision = try #require(execution.precision)
        stage = "initial-complete-evidence-check"
        try check(execution, fixture: fixture, manifest: manifest, modelID: "compound")
        #expect(precision.solutionLow.contains { $0 != 0 })
        #expect(execution.projectedColumns.count == 2 && execution.rows.count > 2)
        let csv = try execution.pairedCSVRecord()
        #expect(csv.compiledRows == execution.projectedColumns && csv.compiledRows != csv.compiledRows.sorted())
        stage = "serialize-and-strict-reload"
        let saved = Data(try CoreSpiceCLIJSON.encode(record).utf8)
        let savedPath = root.appendingPathComponent("complete.json"); try saved.write(to: savedPath)
        let decodedExecution = try #require(JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: savedPath)).osdiExecution)
        let semanticEncoder = JSONEncoder(); semanticEncoder.outputFormatting = [.sortedKeys]
        #expect(try semanticEncoder.encode(decodedExecution) == semanticEncoder.encode(execution))
        #expect(decodedExecution == execution)
        #expect(Set([decodedExecution, execution]).count == 1)
        for corruption in ["low-bits", "high-bits", "time-bits", "interval-low", "first-trapezoidal", "missing-previous", "partial-previous", "program-bytes", "source-bytes", "precision-bits", "equation-atol", "resolved-parameter", "options", "numeric-profile", "semantic-profile", "settings", "raw-map", "row-name", "occurrence", "missing-cold"] {
            stage = "corruption-" + corruption
            var envelope = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            var evidence = try #require(envelope["osdiExecution"] as? [String: Any])
            var paired = try #require(evidence["precision"] as? [String: Any])
            var steps = try #require(evidence["acceptedSteps"] as? [[String: Any]])
            switch corruption {
            case "low-bits", "high-bits", "time-bits":
                let key = corruption == "low-bits" ? "lowBits" : corruption == "high-bits" ? "highBits" : "coordinateBits"
                var bits = try #require(paired[key] as? [NSNumber]); bits[0] = NSNumber(value: bits[0].uint64Value ^ 1); paired[key] = bits
            case "interval-low": steps[0]["timeStepLowComponent"] = 1e-30
            case "first-trapezoidal": steps[0]["method"] = "trapezoidal"
            case "missing-previous":
                let index = try #require(steps.firstIndex { $0["method"] as? String == "trapezoidal" })
                for key in ["previousTimeStepSeconds", "previousTimeStepLowComponent", "previousTimeStepBits", "previousTimeStepLowBits"] { steps[index].removeValue(forKey: key) }
            case "partial-previous":
                let index = try #require(steps.firstIndex { $0["previousTimeStepSeconds"] != nil })
                steps[index].removeValue(forKey: "previousTimeStepLowComponent")
            case "program-bytes":
                var models = try #require(paired["coldModels"] as? [[String: Any]]), program = try #require(models[0]["program"] as? [String: Any])
                program["programBytes"] = "AA=="; models[0]["program"] = program; paired["coldModels"] = models
            case "source-bytes":
                var sources = try #require(paired["sources"] as? [String: Any]), captures = try #require(sources["captures"] as? [[String: Any]])
                captures[0]["bytes"] = "AA=="; sources["captures"] = captures; paired["sources"] = sources
            case "precision-bits":
                var models = try #require(paired["coldModels"] as? [[String: Any]]); models[0]["precisionBits"] = 128; paired["coldModels"] = models
            case "equation-atol":
                var rows = try #require(paired["equationPolicy"] as? [[String: Any]]); rows[0]["equationAbsoluteTolerance"] = 1e-3; paired["equationPolicy"] = rows
            case "options":
                var models = try #require(paired["coldModels"] as? [[String: Any]]), options = try #require(models[0]["options"] as? [String: Any])
                options["maximumWorkUnits"] = 99_999_999; models[0]["options"] = options; paired["coldModels"] = models
            case "numeric-profile", "semantic-profile":
                var models = try #require(paired["coldModels"] as? [[String: Any]])
                if corruption == "numeric-profile" { models[0]["numericProfileSHA256"] = String(repeating: "0", count: 64) }
                else {
                    var program = try #require(models[0]["program"] as? [String: Any]); program["semanticProfileSHA256"] = String(repeating: "0", count: 64); models[0]["program"] = program
                }
                paired["coldModels"] = models
            case "settings":
                var settings = try #require(paired["settings"] as? [String: Any]), convergence = try #require(settings["convergence"] as? [String: Any])
                convergence["reltol"] = 1e-6; settings["convergence"] = convergence; paired["settings"] = settings
            case "raw-map":
                var models = try #require(envelope["osdiModels"] as? [[String: Any]])
                let replacement = try #require(execution.rows.first { $0.sourceName == "q" }).row
                for index in models.indices { models[index]["rawNodeGlobalRows"] = [replacement] }
                envelope["osdiModels"] = models
            case "row-name":
                var rows = try #require(evidence["rows"] as? [[String: Any]])
                rows[0]["sourceName"] = "changed-source-name"; evidence["rows"] = rows
            case "occurrence":
                var sources = try #require(paired["sources"] as? [String: Any]), occurrences = try #require(sources["occurrences"] as? [[String: Any]])
                occurrences[0]["statementOrdinal"] = 1; sources["occurrences"] = occurrences; paired["sources"] = sources
            case "resolved-parameter":
                var models = try #require(envelope["osdiModels"] as? [[String: Any]])
                let modelIndex = try #require(models.firstIndex { $0["phase"] as? String == "tran" })
                var parameters = try #require(models[modelIndex]["resolvedParameters"] as? [[String: Any]])
                let index = try #require(parameters.firstIndex { $0["type"] as? String == "real" })
                let value = try #require(parameters[index]["value"] as? NSNumber).doubleValue
                parameters[index]["value"] = value == 0 ? 1.0 : 0.0
                for phase in models.indices { models[phase]["resolvedParameters"] = parameters }; envelope["osdiModels"] = models
            case "missing-cold": paired["coldModels"] = []
            default: Issue.record("Unknown corruption")
            }
            evidence["acceptedSteps"] = steps; evidence["precision"] = paired; envelope["osdiExecution"] = evidence
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            if corruption == "precision-bits" {
                let inner = try JSONSerialization.data(withJSONObject: evidence)
                let intrinsicallyValid = try JSONDecoder().decode(CoreSpiceCLIOSDIExecutionRecord.self, from: inner)
                #expect(intrinsicallyValid.precision?.coldModels.first?.precisionBits == 128)
            }
            do { _ = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes); Issue.record("Corrupt precision evidence decoded: \(corruption)") }
            catch {
                if ["precision-bits", "equation-atol", "resolved-parameter", "options", "numeric-profile", "semantic-profile", "settings", "raw-map", "row-name", "occurrence"].contains(corruption) {
                    #expect(error is NativePrecisionConfigurationVerification.Failure)
                } else { #expect(error is CoreSpiceCLIOSDIError || error is DecodingError || error is NativePrecisionConfigurationVerification.Failure) }
            }
        }
        // Resource regressions inspect the inner bounded value without granting
        // it full Native completion authority.
        stage = "bounded-metadata-and-plane-regressions"
        let baseEnvelope = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let baseExecution = try #require(baseEnvelope["osdiExecution"] as? [String: Any])
        let basePrecision = try #require(baseExecution["precision"] as? [String: Any])
        do {
            var oversized = basePrecision
            var budget = try #require(oversized["executionBudget"] as? [String: Any]); budget["maximumEvidenceBytes"] = 1024 * 1024
            oversized["executionBudget"] = budget
            var sources = try #require(oversized["sources"] as? [String: Any])
            var captures = try #require(sources["captures"] as? [[String: Any]])
            let key = String(repeating: "k", count: 2048)
            captures[0]["key"] = key; sources["captures"] = captures; sources["rootKey"] = key
            sources["occurrences"] = (0..<1024).map { index -> [String: Any] in
                var occurrence: [String: Any] = ["key": key, "occurrenceID": index]
                if index != 0 { occurrence["parentOccurrenceID"] = 0 }; return occurrence
            }
            oversized["sources"] = sources
            let bytes = try JSONSerialization.data(withJSONObject: oversized)
            let intrinsic = try JSONDecoder().decode(CoreSpiceCLIPrecisionExecution.self, from: bytes)
            do { _ = try intrinsic.serializedUpperBound(execution: execution, models: record.osdiModels); Issue.record("Repeated occurrence metadata bypassed pre-encoding admission") }
            catch { #expect(error is CoreSpiceCLIOSDIError) }
        }
        do {
            var oversized = basePrecision
            var budget = try #require(oversized["executionBudget"] as? [String: Any]); budget["maximumEvidenceBytes"] = 2 * 1024 * 1024
            oversized["executionBudget"] = budget
            let zeros = [Int](repeating: 0, count: 131072)
            for key in ["solutionLow", "highBits", "lowBits", "coordinateBits"] { oversized[key] = zeros }
            let bytes = try JSONSerialization.data(withJSONObject: oversized)
            do { _ = try JSONDecoder().decode(CoreSpiceCLIPrecisionExecution.self, from: bytes); Issue.record("Aggregate precision planes bypassed ownership admission") }
            catch { #expect(error is CoreSpiceCLIOSDIError) }
        }
        let retainedInput = try #require(completed?.output.prepared.input)
        let retainedLimits = try #require(completed?.output.prepared.limits)
        let runtime = try #require(completed?.output.prepared.osdiRuntimeInputs)
        stage = "retained-session-adoption"
        let catalog = try CoreSpiceCLIOSDICatalog.load(path: fixture.catalog.path)
        var session = Session(policy: try .developerV1().applying(catalog.executionBudget))
        try session.adoptPrecision(output: #require(completed?.output), completed: record, catalog: catalog)
        #expect(session.isLoaded)
        completed = nil
        let originalAnalysis = try session.requiredDefaultRunnableAnalysis()
        stage = "retained-session-fresh-run"
        let sessionWaveform = try await session.runParsed(originalAnalysis)
        #expect(session.completedOSDIExecution == execution && sessionWaveform.pointCount == execution.coordinates.count)
        let beforeFailure = session.completedOSDIExecution
        do { _ = try await session.run(.op); Issue.record("Unsupported precision override completed") }
        catch { #expect(session.completedOSDIExecution == beforeFailure && session.lastWaveform != nil) }
        stage = "retained-session-cancelled-run"
        let cancelledSession = CancellationToken(); cancelledSession.cancel()
        do { _ = try await session.runParsed(originalAnalysis, cancellation: cancelledSession); Issue.record("Cancelled retained session completed") }
        catch { #expect(session.completedOSDIExecution == beforeFailure && session.lastWaveform != nil) }
        stage = "direct-native-fresh-run"
        let native = SPICENativeSimulation()
        let owner = try await native.prepare(retainedInput, limits: retainedLimits, osdi: runtime)
        let rerun = try await native.execute(owner, cancellation: .init())
        stage = "direct-native-completion-evidence"
        let budget = try #require(catalog.executionBudget)
        let fresh = try CoreSpiceCLIPreparedRunRecord(rerun, budget: budget)
        #expect(fresh.configurationIdentity == record.configurationIdentity && fresh.osdiExecution == execution)
        try FileManager.default.removeItem(at: fixture.csv); try FileManager.default.removeItem(at: fixture.pairedCSV)
        let cancellation = CancellationToken(); cancellation.cancel()
        do { _ = try await command.execute(cancellation: cancellation); Issue.record("Cancelled precision execution completed") }
        catch { #expect(!FileManager.default.fileExists(atPath: fixture.csv.path) && !FileManager.default.fileExists(atPath: fixture.pairedCSV.path)) }
            } catch {
            print("OSDI precision compound failed stage=\(stage) error=\(error)")
            throw error
        }
    }

    @Test func precisionPublicationRefusesAliasesAndPreservesExistingFiles() async throws {
        let manifest = try manifest(), root = try root("publication-alias")
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: "compound", manifest: manifest, root: root)
        defer { do { try cleanup(root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let source = try Data(contentsOf: fixture.deck)
        let catalog = try CoreSpiceCLIOSDICatalog.load(path: fixture.catalog.path)
        let hardlink = root.appendingPathComponent("source-hardlink"), symlink = root.appendingPathComponent("source-symlink")
        try FileManager.default.linkItem(at: fixture.deck, to: hardlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.deck)
        for target in [fixture.deck.path, hardlink.path, symlink.path] + catalog.protectedInputPaths {
            let args = [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", target]
            do { _ = try await CoreSpicePreparedCommand(arguments: args).execute(); Issue.record("Precision input alias accepted") }
            catch { #expect(error is CoreSpiceCLIOSDIError) }
        }
        let existing = root.appendingPathComponent("existing.csv"), sentinel = Data("keep existing output".utf8)
        try sentinel.write(to: existing)
        do { _ = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", existing.path]).execute(); Issue.record("Existing precision output accepted") }
        catch { #expect(try Data(contentsOf: existing) == sentinel) }
        let fresh = root.appendingPathComponent("fresh.csv")
        let arguments = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fresh.path, "--paired-csv", fresh.path]
        var session = Session(policy: try .developerV1())
        do { _ = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session); Issue.record("Output aliases accepted") }
        catch { #expect(error is CoreSpiceCLIOSDIError && !FileManager.default.fileExists(atPath: fresh.path)) }
        #expect(try Data(contentsOf: fixture.deck) == source)
        // A destination appearing after preflight is still an exclusive-create refusal.
        var publication = try CoreSpiceCLIPrecisionPublication(inputs: [], outputs: [fresh.path])
        let stage = try publication.stage(for: fresh.path); try Data("new".utf8).write(to: URL(fileURLWithPath: stage))
        try sentinel.write(to: fresh)
        do { try publication.publish(); Issue.record("Raced existing destination replaced") }
        catch {
            do { try publication.failed(error) } catch { #expect(try Data(contentsOf: fresh) == sentinel) }
        }
    }

    @Test func batchWithoutJSONStrictlyChecksCompleteEnvelopeBeforePublication() async throws {
        let manifest = try manifest(), root = try root("no-json-gate")
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: "compound", manifest: manifest, root: root)
        defer { do { try cleanup(root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        var catalog = fixture.catalogJSON
        var budget = try #require(catalog["executionBudget"] as? [String: Any]); budget["maximumEvidenceBytes"] = 1024 * 1024
        catalog["executionBudget"] = budget
        try JSONSerialization.data(withJSONObject: catalog).write(to: fixture.catalog)
        let arguments = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--paired-csv", fixture.pairedCSV.path]
        var session = Session(policy: try .developerV1())
        // The complete invocation metadata is independently owned by this boundary.
        let cli = CLI(arguments: [String(repeating: "a", count: 200_000)])
        do { _ = try await cli.executeBatch(options: .init(arguments: arguments), session: &session); Issue.record("No-JSON precision batch bypassed complete envelope admission") }
        catch { #expect(error is CoreSpiceCLIOSDIError) }
        #expect(!FileManager.default.fileExists(atPath: fixture.csv.path) && !FileManager.default.fileExists(atPath: fixture.pairedCSV.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix(".corespice-precision-") })
    }

    @Test func precisionOutputHashingUsesOriginalSharedCeiling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("precision-hash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Hash fixture cleanup failed: \(error)") } }
        let destination = root.appendingPathComponent("result.csv")
        var publication = try CoreSpiceCLIPrecisionPublication(inputs: [], outputs: [destination.path])
        let staged = try publication.stage(for: destination.path)
        try Data("1234".utf8).write(to: URL(fileURLWithPath: staged))
        let resources = try SPICESimulationResources(maximumLiveBytes: 1024, maximumTemporaryBytes: 1024, maximumWorkUnits: 100, maximumHashedBytes: 7)
        try resources.chargeHashedBytes(4)
        do {
            try publication.chargeHash(path: staged, maximumBytes: 1024, resources: resources)
            Issue.record("Output reference hashing escaped original shared ceiling")
        } catch let error as SPICESimulationResources.ResourceError {
            guard case .hashLimit = error else { Issue.record("Unexpected resource refusal"); return }
            do { try publication.failed(error) } catch { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
        }
    }

}
