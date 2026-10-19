import CircuiteFoundation
import Foundation
import Testing

@testable import CoreSpiceCLICore

/// Coverage for the reproducible `--json` run record contract.
@Suite
struct RunRecordTests {

  // MARK: Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("corespice-run-record-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func removeDirectory(_ url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      Issue.record("failed to remove temporary directory \(url.path): \(error)")
    }
  }

  private func decodeJSONObject(_ text: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(object as? [String: Any], "record must be a single JSON object")
  }

  private func batchFailure(arguments: [String]) async throws -> CoreSpiceCLIFailure {
    let options = try CoreSpiceBatchOptions(arguments: arguments)
    let cli = CLI(arguments: arguments)
    var session = try Session(policy: .developerV1())
    do {
      _ = try await cli.executeBatch(options: options, session: &session)
    } catch {
      return CoreSpiceCLIFailure(error: error)
    }
    throw CLIError.state("expected batch run to fail for arguments: \(arguments)")
  }

  // MARK: Failure record

  @Test
  func failureRecordForNonexistentDeck() async throws {
    let missing = "/nonexistent/\(UUID().uuidString).cir"
    let envelope = try await batchFailure(arguments: ["-b", missing, "--json"])

    #expect(envelope.status == "failed")
    #expect(envelope.code == "io.file-read")
    #expect(envelope.stage == "load")
    #expect(!envelope.message.isEmpty)
    #expect(envelope.suggestedActions?.isEmpty == false)

    let json = try decodeJSONObject(CoreSpiceCLIJSON.encode(envelope))
    #expect(json["status"] as? String == "failed")
    #expect(json["code"] as? String == "io.file-read")
    #expect(json["stage"] as? String == "load")
    #expect((json["message"] as? String)?.isEmpty == false)
  }

  @Test
  func failureRecordForUnparsableDeck() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }

    let deckURL = directory.appendingPathComponent("broken.cir")
    let deck = """
      broken deck
      .unknown_control foo bar
      R1 in out 1k
      .end
      """
    try deck.write(to: deckURL, atomically: true, encoding: .utf8)

    let envelope = try await batchFailure(arguments: ["-b", deckURL.path, "--json"])

    #expect(envelope.status == "failed")
    #expect(envelope.code == "deck.parse")
    #expect(envelope.stage == "parse")
    #expect(!envelope.message.isEmpty)

    let json = try decodeJSONObject(CoreSpiceCLIJSON.encode(envelope))
    #expect(json["status"] as? String == "failed")
    #expect(json["code"] as? String == "deck.parse")
  }

  @Test
  func failureRecordForMissingAnalysisDirective() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }

    let deckURL = directory.appendingPathComponent("no-analysis.cir")
    let deck = """
      resistor only deck
      V1 in 0 dc 1
      R1 in 0 1k
      .end
      """
    try deck.write(to: deckURL, atomically: true, encoding: .utf8)

    let envelope = try await batchFailure(arguments: ["-b", deckURL.path, "--json"])

    #expect(envelope.status == "failed")
    #expect(envelope.code == "cli.missing-analysis-directive")
    #expect(envelope.stage == "analysis")
    #expect(envelope.suggestedActions?.isEmpty == false)
  }

  // MARK: Completed run record

  @Test
  func versionedBatchRunFixtureDecodesFoundationArtifactReferences() throws {
    let fixtureURL = try #require(
      Bundle.module.url(
        forResource: "cli-batch-run-v3",
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
    let record = try JSONDecoder().decode(
      CoreSpiceCLIBatchRunRecord.self,
      from: Data(contentsOf: fixtureURL)
    )

    #expect(record.schemaVersion == .v3)
    #expect(record.solverIdentity == nil)
    #expect(record.executionProfile == nil && record.executionProfileReference == nil)
    #expect(record.resolutionProfile == "pinnedNgspiceNormalV1")
    #expect(record.resolutionSeed == 1)
    #expect(record.resolutionPolicy == "corespice-cli-developer-v1")
    #expect(record.invocation.mode == .externalProcess)
    #expect(record.invocation.executable == "corespice")
    #expect(record.inputArtifacts.first?.descriptor.role == .input)
    #expect(record.inputArtifacts.first?.descriptor.kind == .netlist)
    #expect(record.inputArtifacts.first?.descriptor.format == .spice)
    #expect(record.outputArtifacts.first?.descriptor.role == .output)
    #expect(record.outputArtifacts.first?.descriptor.kind == .waveform)
    #expect(record.outputArtifacts.first?.descriptor.format == .raw)
    #expect(record.producer.identifier == "CoreSpiceCLI")
    let encoded = try JSONEncoder().encode(record)
    let current = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in ["bsim4Models", "bsim45Models", "bsim4NoisePreparationRequested", "bsim4PreparationPolicy"] {
      #expect(current[key] == nil)
    }
    #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: encoded) == record)
    var nullable = current
    nullable["bsim4Models"] = []; nullable["bsim45Models"] = []
    nullable["bsim4NoisePreparationRequested"] = false; nullable["bsim4PreparationPolicy"] = NSNull()
    #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
      from: JSONSerialization.data(withJSONObject: nullable)) == record)
    nullable["bsim4NoisePreparationRequested"] = true
    #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
      from: JSONSerialization.data(withJSONObject: nullable)) == record)
    for (key, value) in [("bsim4Models", [["device": "m1"]] as Any),
                         ("bsim45Models", [["device": "m1"]] as Any),
                         ("bsim4PreparationPolicy", [:] as [String: Any]),
                         ("bsim4Models", NSNull() as Any),
                         ("bsim45Models", false as Any),
                         ("bsim4NoisePreparationRequested", 0 as Any)] {
      var forged = current; forged[key] = value
      do {
        _ = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
          from: JSONSerialization.data(withJSONObject: forged))
        Issue.record("Removed native evidence accepted: \(key)")
      } catch DecodingError.dataCorrupted(let context) {
        #expect(context.debugDescription.contains("Removed native BSIM"))
      }
    }
    var incomplete = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
    var legacySolver = incomplete
    legacySolver["solverIdentity"] = "CoreSpice.SparseLU.Accelerate.v1"
    let legacySolverData = try JSONSerialization.data(withJSONObject: legacySolver)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: legacySolverData)
    }
    incomplete.removeValue(forKey: "diodeModels")
    let missingEvidence = try JSONSerialization.data(withJSONObject: incomplete)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: missingEvidence)
    }
  }

  @Test
  func completedRunRecordContainsIntegrityBackedArtifacts() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }

    let deckURL = directory.appendingPathComponent("rc.cir")
    let deck = """
      rc transient deck
      V1 in 0 dc 5
      R1 in out 1k
      C1 out 0 100n
      .options tranmaxaccepted=250000 tranmaxattempts=1000000 tranmaxiterations=5000000 tranmaxscalars=1000000 tranmaxdimension=256 tranmaxwork=1e15 tranmaxbreakpoints=250000
      .tran 10u 500u
      .meas tran vfinal find V(out) at=400u
      .end
      """
    try deck.write(to: deckURL, atomically: true, encoding: .utf8)

    let csvURL = directory.appendingPathComponent("out.csv")
    let rawURL = directory.appendingPathComponent("out.raw")
    let coverageURL = directory.appendingPathComponent("coverage.json")
    let arguments = [
      "-b", deckURL.path, "--json", "--csv", csvURL.path, "-r", rawURL.path,
      "--coverage-json", coverageURL.path,
    ]
    let options = try CoreSpiceBatchOptions(arguments: arguments)
    #expect(options.jsonOutput)

    let cli = CLI(arguments: arguments)
    var session = try Session(policy: .developerV1())
    let summary = try await cli.executeBatch(options: options, session: &session)

    #expect(summary.status == "succeeded")
    #expect(summary.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
    #expect(summary.invocation.mode == .externalProcess)
    #expect(summary.invocation.executable == "corespice")
    #expect(summary.invocation.arguments == arguments)
    #expect(summary.analyses == ["tran"])
    let inputArtifact = try #require(summary.inputArtifacts.first)
    #expect(summary.inputArtifacts.count == 1)
    #expect(inputArtifact.descriptor.role == .input)
    #expect(inputArtifact.descriptor.kind == .netlist)
    #expect(inputArtifact.descriptor.format == .spice)
    #expect(inputArtifact.digest.algorithm == .sha256)
    #expect(inputArtifact.digest.hexadecimalValue.count == 64)
    #expect(inputArtifact.byteCount == UInt64(Data(deck.utf8).count))
    #expect(summary.producer.identifier == "CoreSpiceCLI")

    #expect(Set(summary.outputArtifacts.map(\.descriptor.format)) == [.raw, .csv, .json])
    #expect(summary.outputArtifacts.allSatisfy { $0.descriptor.role == .output })
    #expect(summary.outputArtifacts.filter { $0.descriptor.kind == .waveform }.count == 2)
    #expect(summary.outputArtifacts.filter { $0.descriptor.kind == .report }.count == 1)
    #expect(summary.outputArtifacts.allSatisfy { $0.digest.algorithm == .sha256 })
    #expect(summary.outputArtifacts.allSatisfy { $0.digest.hexadecimalValue.count == 64 })
    #expect(summary.outputArtifacts.allSatisfy { $0.byteCount > 0 })
    #expect(summary.producer.identifier == "CoreSpiceCLI")
    #expect(summary.producer.version == "0.1.0")
    #expect(FileManager.default.fileExists(atPath: csvURL.path))
    #expect(FileManager.default.fileExists(atPath: rawURL.path))
    #expect(FileManager.default.fileExists(atPath: coverageURL.path))

    let waveform = try #require(summary.waveform)
    #expect(waveform.points > 0)
    #expect(!waveform.variables.isEmpty)
    #expect(waveform.runs == nil)

    let measurement = try #require(summary.measurements.first)
    #expect(measurement.analysis == "tran")
    #expect(measurement.name == "vfinal")
    // At t = 400 us (4 tau), V(out) = 5 * (1 - e^-4) ~ 4.9 V.
    #expect(measurement.value > 4.5 && measurement.value < 5.0)

    let json = try decodeJSONObject(CoreSpiceCLIJSON.encode(summary))
    #expect(json["status"] as? String == "succeeded")
    #expect(json["analyses"] as? [String] == ["tran"])
    #expect((json["inputArtifacts"] as? [[String: Any]])?.count == 1)
    #expect((json["outputArtifacts"] as? [[String: Any]])?.count == 3)
    let measurements = try #require(json["measurements"] as? [[String: Any]])
    #expect(measurements.first?["name"] as? String == "vfinal")
    let waveformJSON = try #require(json["waveform"] as? [String: Any])
    #expect((waveformJSON["points"] as? Int ?? 0) > 0)
  }

  // MARK: Exit-code contract

  @Test
  func runReturnsExitCodeTwoForJSONFailure() async {
    let missing = "/nonexistent/\(UUID().uuidString).cir"
    let exitCode = await CoreSpiceCLI.run(arguments: ["-b", missing, "--json"])
    #expect(exitCode == 2)
  }

  @Test
  func nonJSONFailureKeepsTextExitCodeOne() async {
    let missing = "/nonexistent/\(UUID().uuidString).cir"
    let exitCode = await CoreSpiceCLI.run(arguments: ["-b", missing])
    #expect(exitCode == 1)
  }

  @Test
  func nonJSONBatchRunStillSucceeds() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }

    let deckURL = directory.appendingPathComponent("rc.cir")
    let deck = """
      rc transient deck
      V1 in 0 dc 5
      R1 in out 1k
      C1 out 0 100n
      .options tranmaxaccepted=250000 tranmaxattempts=1000000 tranmaxiterations=5000000 tranmaxscalars=1000000 tranmaxdimension=256 tranmaxwork=1e15 tranmaxbreakpoints=250000
      .tran 10u 100u
      .end
      """
    try deck.write(to: deckURL, atomically: true, encoding: .utf8)

    let csvURL = directory.appendingPathComponent("out.csv")
    let exitCode = await CoreSpiceCLI.run(arguments: ["-b", deckURL.path, "--csv", csvURL.path])
    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: csvURL.path))
  }
}
