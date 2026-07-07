import CoreSpiceAnalysis

enum CoreSpiceOutputFormat: String {
  case raw
  case csv
  case psf

  func outputTargets(path: String) -> OutputTargets {
    switch self {
    case .raw:
      return OutputTargets(raw: path)
    case .csv:
      return OutputTargets(csv: path)
    case .psf:
      return OutputTargets(psf: path)
    }
  }
}

enum CoreSpiceREPLCommand {
  case help
  case source(path: String)
  case run
  case analysis(AnalysisCommand)
  case write(format: CoreSpiceOutputFormat, path: String)

  init(line: String) throws {
    let tokens = line.split(separator: " ").map(String.init)
    guard let command = tokens.first?.lowercased() else {
      throw CLIError.invalidArguments("empty command")
    }
    self = try Self.parse(command: command, tokens: tokens)
  }

  private static func parse(command: String, tokens: [String]) throws -> Self {
    switch command {
    case "help":
      return try parseHelp(tokens: tokens)
    case "source":
      return try parseSource(tokens: tokens)
    case "run":
      return try parseRun(tokens: tokens)
    case "op":
      return try parseOperatingPoint(tokens: tokens)
    case "tran":
      return try parseTransient(tokens: tokens)
    case "ac":
      return .analysis(try parseAC(tokens: tokens))
    case "dc":
      return try parseDC(tokens: tokens)
    case "write":
      return try parseWrite(tokens: tokens)
    default:
      throw CLIError.unknownCommand(command)
    }
  }

  private static func parseHelp(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 1, usage: "help")
    return .help
  }

  private static func parseSource(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 2, usage: "source <path>")
    return .source(path: tokens[1])
  }

  private static func parseRun(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 1, usage: "run")
    return .run
  }

  private static func parseOperatingPoint(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 1, usage: "op")
    return .analysis(.op)
  }

  private static func parseTransient(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 3, usage: "tran <tstep> <tstop>")
    guard let step = parseSPICENumber(tokens[1]), let stop = parseSPICENumber(tokens[2]) else {
      throw CLIError.invalidArguments(
        "tran expects numeric <tstep> <tstop> (SPICE suffixes allowed), got '\(tokens[1])' '\(tokens[2])'"
      )
    }
    return .analysis(.tran(tstep: step, tstop: stop))
  }

  private static func parseDC(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 5, usage: "dc <source> <start> <stop> <step>")
    guard let start = parseSPICENumber(tokens[2]),
      let stop = parseSPICENumber(tokens[3]),
      let step = parseSPICENumber(tokens[4])
    else {
      throw CLIError.invalidArguments(
        "dc expects numeric <start> <stop> <step> (SPICE suffixes allowed)")
    }
    return .analysis(.dcSweep(source: tokens[1], start: start, stop: stop, step: step))
  }

  private static func parseWrite(tokens: [String]) throws -> Self {
    try requireTokenCount(tokens, count: 3, usage: "write raw|csv|psf <path>")
    guard let format = CoreSpiceOutputFormat(rawValue: tokens[1].lowercased()) else {
      throw CLIError.invalidArguments("write expects raw|csv|psf format, got '\(tokens[1])'")
    }
    return .write(format: format, path: tokens[2])
  }

  private static func parseAC(tokens: [String]) throws -> AnalysisCommand {
    let mode = tokens[1].lowercased()
    guard let points = Int(tokens[2]), points > 0 else {
      throw CLIError.invalidArguments(
        "ac expects a positive integer point count, got '\(tokens[2])'")
    }
    guard let start = parseSPICENumber(tokens[3]), let stop = parseSPICENumber(tokens[4]) else {
      throw CLIError.invalidArguments(
        "ac expects numeric <start> <stop> (SPICE suffixes allowed), got '\(tokens[3])' '\(tokens[4])'"
      )
    }
    let sweep: FrequencySweep
    switch mode {
    case "dec", "decade":
      sweep = .decade(start: start, stop: stop, pointsPerDecade: points)
    case "lin", "linear":
      sweep = .linear(start: start, stop: stop, points: points)
    default:
      throw CLIError.invalidArguments("ac expects dec|lin mode, got '\(mode)'")
    }
    return .ac(sweep: sweep)
  }

  private static func requireTokenCount(
    _ tokens: [String],
    count: Int,
    usage: String
  ) throws {
    guard tokens.count == count else {
      throw CLIError.invalidArguments("usage: \(usage)")
    }
  }
}

extension AnalysisCommand {
  var completionLabel: String {
    switch self {
    case .op:
      return "op"
    case .tran:
      return "tran"
    case .ac:
      return "ac"
    case .dcSweep:
      return "dc sweep"
    }
  }

  /// Stable identifier used in the `--json` run envelope (`analyses` field).
  var analysisIdentifier: String {
    switch self {
    case .op:
      return "op"
    case .tran:
      return "tran"
    case .ac:
      return "ac"
    case .dcSweep:
      return "dc"
    }
  }
}
