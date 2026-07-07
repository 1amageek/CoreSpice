import CoreSpiceExporterCSV
import CoreSpiceIO
import CoreSpiceParsedIR
import CoreSpiceWaveform
import Foundation

/// Executes the `corespice measure` subcommand: evaluates `.measure`-grammar
/// specs against a stored waveform CSV without re-running any simulation.
///
/// The spec text is parsed with the same SPICE parser the deck path uses
/// (wrapped as a one-line `.measure` directive) and evaluated with
/// `SPICEMeasureEvaluator`, so post-hoc measurements share grammar and
/// semantics with in-deck `.measure` statements exactly.
struct CoreSpiceMeasureCommand: Sendable {
  let options: CoreSpiceMeasureOptions

  init(options: CoreSpiceMeasureOptions) {
    self.options = options
  }

  func run() async throws {
    let summary = try await execute()
    if options.jsonOutput {
      print(try CoreSpiceCLIRunEnvelope.encodeJSON(summary))
    } else {
      for line in Self.textLines(for: summary.measurements) {
        print(line)
      }
    }
  }

  /// Runs the measurement pipeline and collects the machine-readable
  /// summary. Internal so tests can exercise it without capturing process
  /// output. Any failing spec or measurement throws a typed error; nothing
  /// is skipped.
  func execute() async throws -> CoreSpiceCLIRunEnvelope.MeasureSuccess {
    let waveform = try CSVWaveformReader().read(contentsOfFile: options.waveformPath)
    let evaluator = SPICEMeasureEvaluator()
    var measurements: [CoreSpiceCLIRunEnvelope.Measurement] = []
    measurements.reserveCapacity(options.specs.count)

    for spec in options.specs {
      let measure = try await Self.parseMeasureSpec(spec)
      try Self.checkAnalysisDomain(measure: measure, waveform: waveform)
      let result: SPICEMeasurementResult
      do {
        result = try evaluator.evaluate(measure: measure, waveform: waveform)
      } catch let error as SPICEMeasurementError {
        throw CoreSpiceMeasureCommandError.evaluationFailed(
          measurement: measure.resultName,
          reason: error.errorDescription ?? String(describing: error)
        )
      }
      measurements.append(
        CoreSpiceCLIRunEnvelope.Measurement(
          analysis: result.analysisType.rawValue,
          name: result.name,
          value: result.value,
          unit: result.unit.isEmpty ? nil : result.unit
        ))
    }

    return CoreSpiceCLIRunEnvelope.MeasureSuccess(
      waveformPath: options.waveformPath,
      measurements: measurements,
      waveform: CoreSpiceCLIRunEnvelope.WaveformSummary(
        variables: waveform.variables.map(\.name),
        points: waveform.pointCount
      )
    )
  }

  /// Formats text-mode output: one `name=value [unit]` line per measurement.
  static func textLines(for measurements: [CoreSpiceCLIRunEnvelope.Measurement]) -> [String] {
    measurements.map { measurement in
      guard let unit = measurement.unit else {
        return "\(measurement.name)=\(measurement.value)"
      }
      return "\(measurement.name)=\(measurement.value) \(unit)"
    }
  }

  // MARK: - Spec parsing

  private static let analysisKeywords: Set<String> = ["tran", "ac", "dc", "op"]

  /// Parses one measurement spec (the `.measure` statement body without the
  /// leading `.measure`) through the SPICE deck parser.
  static func parseMeasureSpec(_ spec: String) async throws -> MeasureSpec {
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains("\n"), !trimmed.contains("\r") else {
      throw CoreSpiceMeasureCommandError.specParseFailed(
        spec: spec,
        reason: "measurement spec must be a single line"
      )
    }
    let firstToken = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
    guard let firstToken, analysisKeywords.contains(firstToken.lowercased()) else {
      throw CoreSpiceMeasureCommandError.specParseFailed(
        spec: spec,
        reason: "measurement spec must start with an analysis type (tran, ac, dc, or op)"
      )
    }

    let deck = """
      corespice measure spec
      .measure \(trimmed)
      .end
      """
    let result = await SPICEIO.parse(deck, fileName: nil)
    guard let netlist = result.netlist, !result.hasErrors else {
      let reason =
        result.errors.first.map { String(describing: $0) } ?? "unknown parse failure"
      throw CoreSpiceMeasureCommandError.specParseFailed(spec: spec, reason: reason)
    }
    let measures = netlist.controls.compactMap { control -> MeasureSpec? in
      if case .measure(let measure) = control {
        return measure
      }
      return nil
    }
    guard measures.count == 1, let measure = measures.first else {
      throw CoreSpiceMeasureCommandError.specNotSingleMeasurement(
        spec: spec,
        count: measures.count
      )
    }
    return measure
  }

  // MARK: - Domain check

  /// Rejects measurements whose declared analysis domain does not match the
  /// sweep domain inferred from the CSV. The in-deck batch path silently
  /// skips mismatched measures; the post-hoc path must fail loudly instead.
  static func checkAnalysisDomain(
    measure: MeasureSpec,
    waveform: WaveformData
  ) throws {
    let compatible: Bool
    switch measure.analysisType {
    case .transient:
      compatible = waveform.metadata.analysisType == .transient
    case .ac, .noise:
      compatible = waveform.metadata.analysisType == .ac
    case .dc, .op:
      compatible = waveform.metadata.analysisType == .dc
    }
    guard compatible else {
      throw CoreSpiceMeasureCommandError.analysisDomainMismatch(
        measurement: measure.resultName,
        declared: measure.analysisType.rawValue,
        waveformDomain: Self.describeDomain(of: waveform)
      )
    }
  }

  private static func describeDomain(of waveform: WaveformData) -> String {
    switch waveform.metadata.analysisType {
    case .transient:
      return "a time sweep (tran)"
    case .ac:
      return "a frequency sweep (ac)"
    default:
      return "a '\(waveform.sweepVariable.name)' sweep (dc)"
    }
  }
}
