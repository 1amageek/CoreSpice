import CoreSpiceAnalysis

struct CoreSpiceBatchOptions {
  let deckPath: String
  let outputs: OutputTargets
  let overrideAnalysis: AnalysisCommand?
  let jsonOutput: Bool

  init(arguments: [String]) throws {
    var cursor = CoreSpiceCLIArgumentCursor(arguments: arguments)
    var deckPath: String?
    var outputs = OutputTargets()
    var overrideAnalysis: AnalysisCommand?
    var jsonOutput: Bool?

    while !cursor.isAtEnd {
      let argument = cursor.current
      switch argument {
      case "-b", "--batch":
        try Self.rejectDuplicate(deckPath, argument: argument)
        deckPath = try cursor.nonOptionValue(after: argument)
      case "-r":
        try Self.rejectDuplicate(outputs.raw, argument: argument)
        outputs.raw = try cursor.nonOptionValue(after: argument)
      case "--csv":
        try Self.rejectDuplicate(outputs.csv, argument: argument)
        outputs.csv = try cursor.nonOptionValue(after: argument)
      case "--psf":
        try Self.rejectDuplicate(outputs.psf, argument: argument)
        outputs.psf = try cursor.nonOptionValue(after: argument)
      case "--coverage-json":
        try Self.rejectDuplicate(outputs.coverageJSON, argument: argument)
        outputs.coverageJSON = try cursor.nonOptionValue(after: argument)
      case "--tran":
        try Self.rejectDuplicate(overrideAnalysis, argument: "analysis override")
        overrideAnalysis = try Self.parseTransient(after: argument, cursor: &cursor)
      case "--ac":
        try Self.rejectDuplicate(overrideAnalysis, argument: "analysis override")
        overrideAnalysis = try Self.parseAC(after: argument, cursor: &cursor)
      case "--dc":
        try Self.rejectDuplicate(overrideAnalysis, argument: "analysis override")
        overrideAnalysis = try Self.parseDC(after: argument, cursor: &cursor)
      case "--op":
        try Self.rejectDuplicate(overrideAnalysis, argument: "analysis override")
        overrideAnalysis = .op
        cursor.advance()
      case "--json":
        try Self.rejectDuplicate(jsonOutput, argument: argument)
        jsonOutput = true
        cursor.advance()
      default:
        throw CLIError.invalidArguments("unknown batch argument: \(argument)")
      }
    }

    guard let deckPath else {
      throw CLIError.invalidArguments("missing deck path after --batch")
    }

    self.deckPath = deckPath
    self.outputs = outputs
    self.overrideAnalysis = overrideAnalysis
    self.jsonOutput = jsonOutput ?? false
  }

  private static func parseTransient(
    after argument: String,
    cursor: inout CoreSpiceCLIArgumentCursor
  ) throws -> AnalysisCommand {
    cursor.advance()
    let step = try cursor.nextSPICENumber(for: argument, expected: "numeric <tstep>")
    let stop = try cursor.nextSPICENumber(for: argument, expected: "numeric <tstop>")
    return .tran(tstep: step, tstop: stop)
  }

  private static func parseAC(
    after argument: String,
    cursor: inout CoreSpiceCLIArgumentCursor
  ) throws -> AnalysisCommand {
    cursor.advance()
    let mode = try cursor.nextNonOptionValue(for: argument).lowercased()
    let rawPoints = try cursor.nextNonOptionValue(for: argument)
    guard let points = Int(rawPoints), points > 0 else {
      throw CLIError.invalidArguments(
        "--ac expects a positive integer point count, got '\(rawPoints)'")
    }
    let start = try cursor.nextSPICENumber(for: argument, expected: "numeric <start>")
    let stop = try cursor.nextSPICENumber(for: argument, expected: "numeric <stop>")
    let sweep: FrequencySweep
    switch mode {
    case "dec", "decade":
      sweep = .decade(start: start, stop: stop, pointsPerDecade: points)
    case "lin", "linear":
      sweep = .linear(start: start, stop: stop, points: points)
    default:
      throw CLIError.invalidArguments("--ac expects dec|lin mode, got '\(mode)'")
    }
    return .ac(sweep: sweep)
  }

  private static func parseDC(
    after argument: String,
    cursor: inout CoreSpiceCLIArgumentCursor
  ) throws -> AnalysisCommand {
    cursor.advance()
    let source = try cursor.nextNonOptionValue(for: argument)
    let start = try cursor.nextSPICENumber(for: argument, expected: "numeric <start>")
    let stop = try cursor.nextSPICENumber(for: argument, expected: "numeric <stop>")
    let step = try cursor.nextSPICENumber(for: argument, expected: "numeric <step>")
    return .dcSweep(source: source, start: start, stop: stop, step: step)
  }

  private static func rejectDuplicate<T>(_ value: T?, argument: String) throws {
    if value != nil {
      throw CLIError.invalidArguments("duplicate argument: \(argument)")
    }
  }
}
