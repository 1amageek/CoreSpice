import CircuiteFoundation
import Foundation
import Testing

@testable import CoreSpiceCLICore

/// Coverage for the `corespice measure` post-hoc waveform measurement verb:
/// - FIND ... AT and MAX evaluated against an inline waveform CSV
/// - structured failure record for a missing variable
/// - typed error record for a malformed CSV
/// - text-mode `name=value [unit]` output format
/// - analysis-domain mismatch is a failure, not a skip
/// - exit codes follow the JSON record convention (0 / 2 json / 1 text)
@Suite
struct MeasureCommandTests {

  // MARK: Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("corespice-measure-\(UUID().uuidString)")
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

  private func writeCSV(_ content: String, in directory: URL) throws -> String {
    let url = directory.appendingPathComponent("waveform.csv")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  /// A linear ramp: V(out) rises 0 -> 1 V over 0 -> 10 us; I(v1) falls 2 -> 0 A.
  private let rampCSV = """
    time [s],V(out) [V],I(v1) [A]
    0,0,2
    5e-06,0.5,1
    1e-05,1,0
    """

  private func executeMeasure(
    waveform: String,
    specs: [String]
  ) async throws -> CoreSpiceCLIMeasurementRunRecord {
    var arguments = ["--waveform", waveform]
    for spec in specs {
      arguments += ["--measure", spec]
    }
    let options = try CoreSpiceMeasureOptions(arguments: arguments)
    return try await CoreSpiceMeasureCommand(options: options).execute()
  }

  private func measureFailure(
    waveform: String,
    specs: [String]
  ) async throws -> CoreSpiceCLIFailure {
    do {
      _ = try await executeMeasure(waveform: waveform, specs: specs)
    } catch {
      return CoreSpiceCLIFailure(error: error)
    }
    throw CLIError.state("expected measure run to fail for specs: \(specs)")
  }

  // MARK: FIND ... AT

  @Test
  func findAtEvaluatesStoredWaveform() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let summary = try await executeMeasure(
      waveform: csvPath,
      specs: ["tran vmid FIND V(out) AT=2.5u"]
    )

    #expect(summary.status == "succeeded")
    #expect(summary.invocation.mode == .externalProcess)
    #expect(summary.invocation.executable == "corespice")
    #expect(summary.invocation.arguments.first == "measure")
    #expect(summary.inputArtifact.descriptor.role == .input)
    #expect(summary.inputArtifact.descriptor.kind == .waveform)
    #expect(summary.inputArtifact.descriptor.format == .csv)
    #expect(summary.inputArtifact.digest.algorithm == .sha256)
    #expect(summary.inputArtifact.digest.hexadecimalValue.count == 64)
    #expect(summary.inputArtifact.byteCount == UInt64(Data(rampCSV.utf8).count))
    #expect(summary.waveform.points == 3)
    #expect(summary.waveform.variables == ["V(out)", "I(v1)"])
    let measurement = try #require(summary.measurements.first)
    #expect(measurement.analysis == "tran")
    #expect(measurement.name == "vmid")
    #expect(abs(measurement.value - 0.25) < 1e-12)
    #expect(measurement.unit == "V")
  }

  // MARK: Aggregates

  @Test
  func maxAndAverageAggregatesEvaluate() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let summary = try await executeMeasure(
      waveform: csvPath,
      specs: [
        "tran vpeak MAX V(out)",
        "tran imean AVG I(v1) FROM=0 TO=10u",
      ]
    )

    #expect(summary.measurements.count == 2)
    let peak = summary.measurements[0]
    #expect(peak.name == "vpeak")
    #expect(abs(peak.value - 1.0) < 1e-12)
    #expect(peak.unit == "V")

    let mean = summary.measurements[1]
    #expect(mean.name == "imean")
    #expect(abs(mean.value - 1.0) < 1e-12)
    #expect(mean.unit == "A")
  }

  // MARK: Structured failures

  @Test
  func missingVariableProducesStructuredFailure() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let envelope = try await measureFailure(
      waveform: csvPath,
      specs: ["tran vghost FIND V(nope) AT=5u"]
    )

    #expect(envelope.status == "failed")
    #expect(envelope.code == "measure.evaluation")
    #expect(envelope.stage == "measure")
    #expect(envelope.message.contains("vghost"))
    #expect(envelope.message.contains("V(nope)"))
  }

  @Test
  func timeOutsideWaveformProducesStructuredFailure() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let envelope = try await measureFailure(
      waveform: csvPath,
      specs: ["tran vlate FIND V(out) AT=1m"]
    )

    #expect(envelope.code == "measure.evaluation")
    #expect(envelope.stage == "measure")
    #expect(envelope.message.contains("vlate"))
  }

  @Test
  func analysisDomainMismatchIsFailureNotSkip() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let envelope = try await measureFailure(
      waveform: csvPath,
      specs: ["ac gpeak MAX V(out)"]
    )

    #expect(envelope.code == "measure.analysis-mismatch")
    #expect(envelope.stage == "measure")
    #expect(envelope.message.contains("gpeak"))
  }

  @Test
  func unparsableSpecProducesSpecParseFailure() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let envelope = try await measureFailure(
      waveform: csvPath,
      specs: ["vfinal FIND V(out) AT=5u"]
    )

    #expect(envelope.code == "measure.spec-parse")
    #expect(envelope.stage == "parse")
  }

  // MARK: Malformed CSV

  @Test
  func malformedCSVProducesTypedErrorEnvelope() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(
      """
      time [s],V(out) [V]
      0,not-a-number
      """,
      in: directory
    )

    let envelope = try await measureFailure(
      waveform: csvPath,
      specs: ["tran vfinal FIND V(out) AT=0"]
    )

    #expect(envelope.status == "failed")
    #expect(envelope.code == "waveform.csv-read")
    #expect(envelope.stage == "load")
    #expect(envelope.message.contains("not-a-number"))
  }

  @Test
  func rowWidthMismatchProducesTypedErrorEnvelope() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(
      """
      time [s],V(out) [V]
      0,1,7
      """,
      in: directory
    )

    let envelope = try await measureFailure(
      waveform: csvPath,
      specs: ["tran vfinal FIND V(out) AT=0"]
    )

    #expect(envelope.code == "waveform.csv-read")
    #expect(envelope.stage == "load")
  }

  // MARK: Text mode

  @Test
  func textModeFormatsNameValueUnit() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    // Binary-exact time values so the interpolated result is exactly 0.5.
    let csvPath = try writeCSV(
      """
      time [s],V(out) [V]
      0,0
      2,1
      """,
      in: directory
    )

    let summary = try await executeMeasure(
      waveform: csvPath,
      specs: ["tran vmid FIND V(out) AT=1"]
    )

    let lines = CoreSpiceMeasureCommand.textLines(for: summary.measurements)
    #expect(lines == ["vmid=0.5 V"])
  }

  @Test
  func textModeOmitsEmptyUnit() {
    let measurements = [
      CoreSpiceCLIMeasurement(
        analysis: "tran", name: "ratio", value: 2.0, unit: nil)
    ]
    #expect(CoreSpiceMeasureCommand.textLines(for: measurements) == ["ratio=2.0"])
  }

  // MARK: JSON record shape

  @Test
  func measurementRecordEncodesStableArtifactShape() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let summary = try await executeMeasure(
      waveform: csvPath,
      specs: ["tran vmid FIND V(out) AT=5u"]
    )
    let object = try JSONSerialization.jsonObject(
      with: Data(CoreSpiceCLIJSON.encode(summary).utf8))
    let json = try #require(object as? [String: Any])

    #expect(json["status"] as? String == "succeeded")
    let inputArtifact = try #require(json["inputArtifact"] as? [String: Any])
    #expect((inputArtifact["byteCount"] as? Int ?? 0) > 0)
    let digest = try #require(inputArtifact["digest"] as? [String: Any])
    #expect(digest["algorithm"] as? String == "sha256")
    #expect((digest["hexadecimalValue"] as? String)?.count == 64)
    let measurements = try #require(json["measurements"] as? [[String: Any]])
    #expect(measurements.count == 1)
    #expect(measurements[0]["name"] as? String == "vmid")
    #expect(measurements[0]["unit"] as? String == "V")
    let waveform = try #require(json["waveform"] as? [String: Any])
    #expect(waveform["points"] as? Int == 3)
  }

  // MARK: Exit codes

  @Test
  func exitCodesFollowJSONRecordConvention() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeDirectory(directory) }
    let csvPath = try writeCSV(rampCSV, in: directory)

    let success = await CoreSpiceCLI.run(arguments: [
      "measure", "--waveform", csvPath,
      "--measure", "tran vmid FIND V(out) AT=5u", "--json",
    ])
    #expect(success == 0)

    let jsonFailure = await CoreSpiceCLI.run(arguments: [
      "measure", "--waveform", csvPath,
      "--measure", "tran vghost FIND V(nope) AT=5u", "--json",
    ])
    #expect(jsonFailure == 2)

    let textFailure = await CoreSpiceCLI.run(arguments: [
      "measure", "--waveform", csvPath,
      "--measure", "tran vghost FIND V(nope) AT=5u",
    ])
    #expect(textFailure == 1)
  }
}
