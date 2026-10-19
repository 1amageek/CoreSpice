import CoreSpiceAnalysis
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts

struct CoreSpiceBatchOptions {
  let network: CoreSpiceCLINetworkOptions?
  let touchstonePath: String?
  let networkDirectory: String?
  let executionProfilePath: String?
  let osdiCatalogPath: String?
  let pairedCSVPath: String?
  let deckPath: String
  let outputs: OutputTargets
  let overrideAnalysis: AnalysisCommand?
  let jsonOutput: Bool
  let profile: MOSInputProfile
  let diodeProfile: DiodeInputProfile
  let randomSeed: UInt64?
  let caseOutput: String?
  let caseID: String?

  init(arguments: [String]) throws {
    var cursor = CoreSpiceCLIArgumentCursor(arguments: arguments)
    var osdiCatalogPath: String?
    var executionProfilePath: String?
    var pairedCSVPath: String?
    var deckPath: String?
    var outputs = OutputTargets()
    var overrideAnalysis: AnalysisCommand?
    var jsonOutput: Bool?
    var profile: MOSInputProfile?
    var diodeProfile: DiodeInputProfile?
    var randomSeed: UInt64?
    var caseOutput: String?
    var caseID: String?
    var analysisIndex: Int?
    var networkPorts: [NetworkPort] = []
    var networkTolerance: Double?
    var touchstonePath: String?
    var networkDirectory: String?

    while !cursor.isAtEnd {
      let argument = cursor.current
      switch argument {
      case "--analysis-index":
        try Self.rejectDuplicate(analysisIndex, argument: argument)
        let raw = try cursor.nonOptionValue(after: argument)
        guard let value = Int(raw), value >= 0 else { throw CLIError.invalidArguments("--analysis-index requires a nonnegative source index") }
        analysisIndex = value
      case "--network-port":
        cursor.advance()
        let source = try cursor.nextNonOptionValue(for: argument)
        let raw = try cursor.nextNonOptionValue(for: argument)
        guard let reference = Double(raw) else { throw CLIError.invalidArguments("--network-port requires a source and positive finite resistance") }
        networkPorts.append(try .init(voltageSourceName: source, referenceImpedance: reference))
      case "--network-residual-tolerance":
        try Self.rejectDuplicate(networkTolerance, argument: argument)
        let raw = try cursor.nonOptionValue(after: argument)
        guard let value = Double(raw) else { throw CLIError.invalidArguments("Invalid network residual tolerance") }
        networkTolerance = value
      case "--touchstone":
        try Self.rejectDuplicate(touchstonePath, argument: argument)
        touchstonePath = try cursor.nonOptionValue(after: argument)
      case "--network-output-directory":
        try Self.rejectDuplicate(networkDirectory, argument: argument)
        networkDirectory = try cursor.nonOptionValue(after: argument)
      case "--execution-profile":
        try Self.rejectDuplicate(executionProfilePath, argument: argument)
        executionProfilePath = try cursor.nonOptionValue(after: argument)
      case "-b", "--batch":
        try Self.rejectDuplicate(deckPath, argument: argument)
        deckPath = try cursor.nonOptionValue(after: argument)
      case "--osdi-catalog":
        try Self.rejectDuplicate(osdiCatalogPath, argument: argument)
        osdiCatalogPath = try cursor.nonOptionValue(after: argument)
      case "--paired-csv":
        try Self.rejectDuplicate(pairedCSVPath, argument: argument)
        pairedCSVPath = try cursor.nonOptionValue(after: argument)
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
      case "--case-output":
        try Self.rejectDuplicate(caseOutput, argument: argument)
        caseOutput = try cursor.nonOptionValue(after: argument)
      case "--case-id":
        try Self.rejectDuplicate(caseID, argument: argument)
        caseID = try cursor.nonOptionValue(after: argument)
      case "--mos-profile":
        try Self.rejectDuplicate(profile, argument: argument)
        let raw = try cursor.nonOptionValue(after: argument)
        guard let parsed = MOSInputProfile(rawValue: raw) else {
          throw CLIError.invalidArguments("--mos-profile expects coreStrictV1 or pinnedNgspiceNormalV1")
        }
        profile = parsed
      case "--diode-profile":
        try Self.rejectDuplicate(diodeProfile, argument: argument)
        let raw = try cursor.nonOptionValue(after: argument)
        guard let parsed = CoreSpiceCLIDiodeRecord.profile(named: raw) else {
          throw CLIError.invalidArguments("--diode-profile expects coreDiodeV1 or genericDiodeV1")
        }
        diodeProfile = parsed
      case "--seed":
        try Self.rejectDuplicate(randomSeed, argument: argument)
        let rawSeed = try cursor.nonOptionValue(after: argument)
        guard let seed = UInt64(rawSeed) else {
          throw CLIError.invalidArguments(
            "--seed expects a nonnegative integer, got '\(rawSeed)'"
          )
        }
        randomSeed = seed
      default:
        throw CLIError.invalidArguments("unknown batch argument: \(argument)")
      }
    }

    guard let deckPath else {
      throw CLIError.invalidArguments("missing deck path after --batch")
    }

    guard (caseOutput == nil) == (caseID == nil) else {
      throw CLIError.invalidArguments("--case-output and --case-id must be supplied together")
    }
    network = try networkPorts.isEmpty && networkTolerance == nil ? nil
        : CoreSpiceCLINetworkOptions(analysisIndex: analysisIndex, ports: networkPorts, residualTolerance: networkTolerance)
    guard network != nil || (analysisIndex == nil && touchstonePath == nil && networkDirectory == nil) else {
      throw CLIError.invalidArguments("Network outputs and source index require explicit network ports/tolerance")
    }
    guard network == nil || overrideAnalysis == nil else { throw CLIError.invalidArguments("Network extraction requires the selected source AC; analysis override is incompatible") }
    self.touchstonePath = touchstonePath; self.networkDirectory = networkDirectory
    self.profile = profile ?? .pinnedNgspiceNormalV1
    self.diodeProfile = diodeProfile ?? .genericDiodeV1
    self.caseOutput = caseOutput
    self.caseID = caseID
    self.osdiCatalogPath = osdiCatalogPath
    self.executionProfilePath = executionProfilePath
    self.pairedCSVPath = pairedCSVPath
    self.deckPath = deckPath
    self.outputs = outputs
    self.overrideAnalysis = overrideAnalysis
    self.jsonOutput = jsonOutput ?? false
    self.randomSeed = randomSeed
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
