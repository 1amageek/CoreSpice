import CoreSpiceIO
import Foundation
import Testing

@testable import CoreSpiceCLICore

/// Regression coverage for the CLI analysis-setup defects found while
/// cross-validating against ngspice:
/// - SPICE engineering suffixes (20p, 50n) were dropped because the CLI used
///   raw `Double(_:)`, silently falling back to a 1 us stop time.
/// - The explicit `--tran` flag fed 0/0 into the transient config, producing a
///   NaN-driven `fatalError`.
@Suite
struct AnalysisSetupTests {

  private func approxEqual(_ value: Double?, _ expected: Double, rel: Double = 1e-12) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= rel * max(1.0, abs(expected))
  }

  // MARK: SPICE number parsing

  @Test
  func parsesEngineeringSuffixes() {
    #expect(approxEqual(parseSPICENumber("20p"), 20e-12))
    #expect(approxEqual(parseSPICENumber("50n"), 50e-9))
    #expect(approxEqual(parseSPICENumber("4.7k"), 4700))
    #expect(approxEqual(parseSPICENumber("1meg"), 1e6))
    #expect(approxEqual(parseSPICENumber("1e-9"), 1e-9))
  }

  @Test
  func parsesSignedEngineeringSuffixes() {
    #expect(approxEqual(parseSPICENumber("-1"), -1))
    #expect(approxEqual(parseSPICENumber("+2.5m"), 2.5e-3))
    #expect(approxEqual(parseSPICENumber("-20p"), -20e-12))
  }

  @Test
  func rejectsNonNumericInput() {
    #expect(parseSPICENumber("abc") == nil)
    #expect(parseSPICENumber("") == nil)
    #expect(parseSPICENumber("1qq") == nil)
    #expect(parseSPICENumber("1 2") == nil)
    #expect(parseSPICENumber("1e309") == nil)
  }

  // MARK: CLI argument contracts

  @Test
  func batchOptionsRejectOptionTokenAsDeckPath() {
    #expect(throws: CLIError.self) {
      _ = try CoreSpiceBatchOptions(arguments: ["--batch", "--csv", "out.csv"])
    }
  }

  @Test
  func batchOptionsRejectMissingTransientValue() {
    #expect(throws: CLIError.self) {
      _ = try CoreSpiceBatchOptions(arguments: ["--batch", "deck.cir", "--tran", "1n"])
    }
  }

  @Test
  func batchOptionsParseNegativeDCSweepValues() throws {
    let options = try CoreSpiceBatchOptions(
      arguments: ["--batch", "deck.cir", "--dc", "V1", "-1", "1", "0.5"]
    )
    guard case .dcSweep(let source, let start, let stop, let step) = options.overrideAnalysis else {
      Issue.record("expected dc sweep override")
      return
    }
    #expect(source == "V1")
    #expect(approxEqual(start, -1))
    #expect(approxEqual(stop, 1))
    #expect(approxEqual(step, 0.5))
  }

  @Test
  func replRejectsUnknownWriteFormat() {
    #expect(throws: CLIError.self) {
      _ = try CoreSpiceREPLCommand(line: "write bogus out.raw")
    }
  }

  @Test
  func replRejectsUnsupportedACMode() {
    #expect(throws: CLIError.self) {
      _ = try CoreSpiceREPLCommand(line: "ac octave 10 1 1k")
    }
  }

  // MARK: Deck analysis selection

  @Test
  func transientDirectiveWithSuffixesIsResolved() async throws {
    let deck = """
      suffix tran
      V1 vdd 0 dc 1.8
      R1 vdd n1 1k
      C1 n1 0 20f
      .tran 20p 50n
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "suffix.cir")

    let analysis = try #require(session.firstRunnableAnalysis)
    guard case .transient(let spec) = analysis else {
      Issue.record("expected transient analysis, got \(analysis)")
      return
    }
    guard case .numeric(let stop) = spec.stopTime else {
      Issue.record("expected numeric stop time, got \(spec.stopTime)")
      return
    }
    #expect(approxEqual(stop, 50e-9))

    let step = try #require(spec.stepTime)
    guard case .numeric(let stepValue) = step else {
      Issue.record("expected numeric step time, got \(step)")
      return
    }
    #expect(approxEqual(stepValue, 20e-12))
  }

  @Test
  func transientUICAppliesNodeInitialConditionToInitialSample() async throws {
    let deck = """
      uic initial condition deck
      V1 in 0 dc 1.0
      R1 in out 1k
      C1 out 0 1p
      .ic V(out)=0.42
      .tran 1n 1n uic
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "uic.cir")

    let analysis = try #require(session.firstRunnableAnalysis)
    guard case .transient(let spec) = analysis else {
      Issue.record("expected transient analysis, got \(analysis)")
      return
    }
    #expect(spec.useInitialConditions)

    let waveform = try await session.runParsed(analysis)
    let outIndex = try #require(waveform.variables.firstIndex { $0.name == "V(out)" })
    let initialOut = try #require(waveform.realValue(variable: outIndex, point: 0))
    #expect(approxEqual(initialOut, 0.42, rel: 1e-9))
  }

  @Test
  func initialConditionRejectsUnknownNodeAtLoadTime() async throws {
    let deck = """
      bad initial condition node deck
      V1 in 0 dc 1.0
      R1 in 0 1k
      .ic V(missing)=0.42
      .tran 1n 1n uic
      .end
      """
    var session = Session()
    do {
      try await session.loadNetlist(source: deck, fileName: "missing-ic.cir")
      Issue.record("expected unknown .ic node to fail during load")
    } catch let error as CLIError {
      guard case .invalidArguments(let message) = error else {
        Issue.record("expected invalidArguments, got \(error)")
        return
      }
      #expect(message.contains("unknown node"))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func operatingPointDirectiveIsSelected() async throws {
    let deck = """
      op deck
      V1 1 0 dc 1
      R1 1 0 1k
      .op
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "op.cir")

    let analysis = try #require(session.firstRunnableAnalysis)
    guard case .op = analysis else {
      Issue.record("expected operating point, got \(analysis)")
      return
    }
  }

  @Test
  func defaultAnalysisRejectsUnsupportedDirectiveInsteadOfOperatingPointFallback() async throws {
    let deck = """
      noise deck
      V1 in 0 dc 1
      R1 in out 1k
      R2 out 0 1k
      .noise V(out) V1 dec 10 1 1meg
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "noise.cir")

    #expect(session.firstRunnableAnalysis == nil)
    do {
      _ = try session.defaultRunnableAnalysis()
      Issue.record("expected unsupported analysis directive to fail")
    } catch let error as CLIError {
      guard case .unsupportedAnalysis(let analysis) = error else {
        Issue.record("expected unsupportedAnalysis, got \(error)")
        return
      }
      #expect(analysis == "noise")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func defaultAnalysisRejectsMissingDirectiveInsteadOfOperatingPointFallback() async throws {
    let deck = """
      no analysis deck
      V1 1 0 dc 1
      R1 1 0 1k
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "no-analysis.cir")

    #expect(session.firstRunnableAnalysis == nil)
    #expect(try session.defaultRunnableAnalysis() == nil)
    #expect(throws: CLIError.self) {
      _ = try session.requiredDefaultRunnableAnalysis()
    }
    do {
      _ = try await session.run(.op)
    } catch {
      Issue.record("explicit operating point remains supported and should not fail: \(error)")
    }
  }

  @Test
  func requiredDefaultRunnableAnalysisRejectsMissingDirective() async throws {
    var session = Session()
    try await session.loadNetlist(
      source: """
        no analysis deck
        V1 1 0 dc 1
        R1 1 0 1k
        .end
        """,
      fileName: "no-analysis.cir"
    )

    do {
      _ = try session.requiredDefaultRunnableAnalysis()
      Issue.record("expected missing analysis directive to fail")
    } catch let error as CLIError {
      guard case .missingAnalysisDirective = error else {
        Issue.record("expected missingAnalysisDirective, got \(error)")
        return
      }
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func sessionResolvesOptionsAndOperatingPointMeasurements() async throws {
    let deck = """
      op measure deck
      V1 1 0 dc 2
      R1 1 2 1k
      R2 2 0 1k
      .options reltol=1e-4
      .op
      .meas op vout find V(2) at=0
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "op-measure.cir")

    #expect(approxEqual(session.analysisOptions.convergence.reltol, 1e-4))

    let analysis = try #require(session.firstRunnableAnalysis)
    _ = try await session.runParsed(analysis)

    let measurement = try #require(session.lastMeasurements.first)
    #expect(measurement.analysisType == .op)
    #expect(measurement.name == "vout")
    #expect(approxEqual(measurement.value, 1.0, rel: 1e-9))
    #expect(measurement.unit == "V")
  }

  @Test
  func parsedDCSweepResolvesParameterExpressions() async throws {
    let deck = """
      parameterized dc deck
      .param vstop=1 vstep={vstop/2}
      V1 in 0 dc 0
      R1 in 0 1k
      .dc V1 0 {vstop} {vstep}
      .end
      """
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: "parameterized-dc.cir")

    let analysis = try #require(session.firstRunnableAnalysis)
    let waveform = try await session.runParsed(analysis)

    #expect(waveform.metadata.analysisType == .dc)
    #expect(waveform.sweepValues.count == 3)
    #expect(approxEqual(waveform.sweepValues[safe: 0], 0.0))
    #expect(approxEqual(waveform.sweepValues[safe: 1], 0.5))
    #expect(approxEqual(waveform.sweepValues[safe: 2], 1.0))
  }

  @Test
  func parsedDCSweepRejectsUnknownSource() async throws {
    let deck = """
      bad dc source deck
      V1 in 0 dc 0
      R1 in 0 1k
      .dc VMISSING 0 1 0.5
      .end
      """
    try await expectParsedRunFailure(
      deck: deck,
      fileName: "missing-dc-source.cir",
      containing: "was not found"
    )
  }

  @Test
  func parsedDCSweepRejectsNonSourceInstance() async throws {
    let deck = """
      bad dc source type deck
      V1 in 0 dc 0
      R1 in 0 1k
      .dc R1 0 1 0.5
      .end
      """
    try await expectParsedRunFailure(
      deck: deck,
      fileName: "non-source-dc.cir",
      containing: "must be an independent voltage or current source"
    )
  }

  @Test
  func parsedDCSweepRejectsUnresolvedExpressions() async throws {
    let deck = """
      unresolved dc expression deck
      V1 in 0 dc 0
      R1 in 0 1k
      .dc V1 0 {missing_stop} 0.5
      .end
      """
    try await expectParsedRunFailure(
      deck: deck,
      fileName: "unresolved-dc-expression.cir",
      containing: "dc.stop could not be resolved"
    )
  }

  private func expectParsedRunFailure(
    deck: String,
    fileName: String,
    containing expectedMessage: String
  ) async throws {
    var session = Session()
    try await session.loadNetlist(source: deck, fileName: fileName)
    let analysis = try #require(session.firstRunnableAnalysis)

    do {
      _ = try await session.runParsed(analysis)
      Issue.record("expected parsed analysis to fail")
    } catch let error as CLIError {
      guard case .invalidArguments(let message) = error else {
        Issue.record("expected invalidArguments, got \(error)")
        return
      }
      #expect(message.contains(expectedMessage))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}
