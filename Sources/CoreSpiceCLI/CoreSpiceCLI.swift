import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceBackend
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceExporter
import CoreSpiceExporterCSV
import CoreSpiceExporterPSF
import CoreSpiceExporterRAW
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceOptoelectronics
import CircuiteFoundation
import Foundation

public enum CoreSpiceCLI {
  public static func run() async -> Int {
    await run(arguments: Array(CommandLine.arguments.dropFirst()))
  }

  /// Runs the CLI with explicit arguments.
  ///
  /// Exit codes: 0 on success, 1 on failure in text mode, 2 when a `--json`
  /// failure record was written to stdout.
  static func run(arguments: [String]) async -> Int {
    let jsonMode = arguments.contains("--json")
    do {
      var cli = CLI(arguments: arguments)
      try await cli.run()
      return 0
    } catch {
      guard jsonMode else {
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 1
      }
      let failure = CoreSpiceCLIFailure(error: error)
      do {
        print(try CoreSpiceCLIJSON.encode(failure))
        return 2
      } catch let encodingError {
        fputs(
          "error: failed to encode JSON failure record: \(String(describing: encodingError))\n",
          stderr
        )
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 1
      }
    }
  }
}

// MARK: - CLI Frontend

struct CLI {
  private let args: [String]

  init(arguments: [String]) {
    self.args = arguments
  }

  mutating func run() async throws {
    if let convergenceObjectiveIndex = args.firstIndex(where: {
      $0 == "convergence-recovery-objective" || $0 == "--convergence-recovery-objective"
    }) {
      let remainingArguments = Array(args.dropFirst(convergenceObjectiveIndex + 1))
      let command = try CoreSpiceConvergenceRecoveryObjectiveCommand(arguments: remainingArguments)
      try command.run()
      return
    }

    if let metricObjectiveIndex = args.firstIndex(where: {
      $0 == "metric-improvement-objective" || $0 == "--metric-improvement-objective"
    }) {
      let remainingArguments = Array(args.dropFirst(metricObjectiveIndex + 1))
      let command = try CoreSpiceMetricImprovementObjectiveCommand(arguments: remainingArguments)
      try command.run()
      return
    }

    if let actionDomainIndex = args.firstIndex(where: {
      $0 == "--action-domain" || $0 == "action-domain"
    }) {
      let remainingArguments = Array(args.dropFirst(actionDomainIndex + 1))
      let command = try CoreSpiceActionDomainCommand(arguments: remainingArguments)
      try command.run()
      return
    }

    if args.first == "measure" {
      let options = try CoreSpiceMeasureOptions(arguments: Array(args.dropFirst()))
      let command = CoreSpiceMeasureCommand(options: options)
      try await command.run()
      return
    }

    if args.contains("-h") || args.contains("--help") {
      printHelp()
      return
    }

    if let versionFlag = args.first(where: { $0 == "-v" || $0 == "--version" }) {
      print("CoreSpice CLI 0.1.0 (\(versionFlag))")
      return
    }

    // Batch mode
    if args.contains(where: { $0 == "-b" || $0 == "--batch" }) {
      let options = try CoreSpiceBatchOptions(arguments: args)
      try await runBatch(options: options)
      return
    }

    // Interactive REPL
    var session = Session()
    print("CoreSpice interactive shell. Type 'help' for commands.")
    while true {
      fputs("corespice> ", stdout)
      guard let line = readLine() else { break }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      do {
        if trimmed == "quit" || trimmed == "exit" { break }
        try await handle(line: trimmed, session: &session)
      } catch {
        print("error: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Batch

  private func runBatch(
    options: CoreSpiceBatchOptions
  ) async throws {
    var session = Session()
    let summary = try await executeBatch(options: options, session: &session)
    if options.jsonOutput {
      print(try CoreSpiceCLIJSON.encode(summary))
    } else {
      printMeasurements(session.lastMeasurements)
    }
  }

  /// Runs a batch invocation and collects the machine-readable run summary.
  /// Internal so tests can exercise the batch pipeline without capturing
  /// process output.
  func executeBatch(
    options: CoreSpiceBatchOptions,
    session: inout Session
  ) async throws -> CoreSpiceCLIBatchRunRecord {
    let loadedDeck = try await SPICEDeckLoader.loadFile(at: options.deckPath)
    let artifactReferencer = try CoreSpiceCLIArtifactReferencer()
    let inputArtifacts = try loadedDeck.inputPaths.map { path in
      try artifactReferencer.input(path: path, kind: .netlist, format: .spice)
    }
    var outputArtifacts: [ArtifactReference] = []
    if let coveragePath = options.outputs.coverageJSON {
      try writeCoverageReport(loadedDeck.coverage, path: coveragePath)
      outputArtifacts.append(
        try artifactReferencer.output(path: coveragePath, kind: .report, format: .json)
      )
    }
    try session.loadNetlist(loadedDeck, randomSeed: options.randomSeed)
    reportOptionDiagnostics(session.analysisOptions.diagnostics)
    let analyses: [String]
    let waveformSummary: CoreSpiceCLIWaveformSummary?
    if let mc = session.monteCarloSpec {
      let parametric = try await session.runMonteCarlo(
        spec: mc,
        inner: mc.analysis,
        seedOverride: options.randomSeed
      )
      outputArtifacts += try await export(parametric: parametric, outputs: options.outputs)
      analyses = ["mc(\(Session.analysisName(mc.analysis)))"]
      waveformSummary = parametric.runs.first.map { first in
        CoreSpiceCLIWaveformSummary(
          variables: first.waveform.variables.map(\.name),
          points: first.waveform.pointCount,
          runs: parametric.runs.count
        )
      }
    } else if let override = options.overrideAnalysis {
      let waveform = try await session.run(override)
      outputArtifacts += try await export(waveform: waveform, outputs: options.outputs)
      analyses = [override.analysisIdentifier]
      waveformSummary = CoreSpiceCLIWaveformSummary(
        variables: waveform.variables.map(\.name),
        points: waveform.pointCount
      )
    } else {
      let parsed = try session.requiredDefaultRunnableAnalysis()
      let waveform = try await session.runParsed(parsed)
      outputArtifacts += try await export(waveform: waveform, outputs: options.outputs)
      analyses = [Session.analysisName(parsed)]
      waveformSummary = CoreSpiceCLIWaveformSummary(
        variables: waveform.variables.map(\.name),
        points: waveform.pointCount
      )
    }
    return CoreSpiceCLIBatchRunRecord(
      invocation: try ExecutionInvocation.externalProcess(
        executable: "corespice",
        arguments: args,
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      inputArtifacts: inputArtifacts,
      outputArtifacts: outputArtifacts,
      analyses: analyses,
      measurements: session.lastMeasurements.map { measurement in
        CoreSpiceCLIMeasurement(
          analysis: measurement.analysisType.rawValue,
          name: measurement.name,
          value: measurement.value,
          unit: measurement.unit.isEmpty ? nil : measurement.unit
        )
      },
      waveform: waveformSummary
    )
  }

  // MARK: REPL command handling

  private func handle(line: String, session: inout Session) async throws {
    let command = try CoreSpiceREPLCommand(line: line)
    try await execute(command, session: &session)
  }

  private func execute(_ command: CoreSpiceREPLCommand, session: inout Session) async throws {
    switch command {
    case .help:
      printHelp()
    case .source(let path):
      try await source(path, session: &session)
    case .run:
      try await runDefaultAnalysis(session: &session)
    case .analysis(let analysis):
      try await run(analysis, session: &session)
    case .write(let format, let path):
      try await write(format: format, path: path, session: &session)
    }
  }

  private func source(_ path: String, session: inout Session) async throws {
    let loadedDeck = try await SPICEDeckLoader.loadFile(at: path)
    try session.loadNetlist(loadedDeck)
    reportOptionDiagnostics(session.analysisOptions.diagnostics)
    print("loaded \(path)")
  }

  private func runDefaultAnalysis(session: inout Session) async throws {
    guard session.isLoaded else {
      throw CLIError.state("no netlist loaded; use 'source <path>'")
    }
    if let mc = session.monteCarloSpec {
      _ = try await session.runMonteCarlo(spec: mc, inner: mc.analysis)
      print("monte carlo complete (\(mc.iterations) runs)")
    } else {
      let parsed = try session.requiredDefaultRunnableAnalysis()
      _ = try await session.runParsed(parsed)
      print("analysis complete")
    }
    printMeasurements(session.lastMeasurements)
  }

  private func run(_ analysis: AnalysisCommand, session: inout Session) async throws {
    guard session.isLoaded else {
      throw CLIError.state("no netlist loaded")
    }
    _ = try await session.run(analysis)
    print("\(analysis.completionLabel) complete")
    printMeasurements(session.lastMeasurements)
  }

  private func write(
    format: CoreSpiceOutputFormat,
    path: String,
    session: inout Session
  ) async throws {
    guard let waveform = session.lastWaveform else {
      throw CLIError.state("no result to write; run an analysis first")
    }
    try await export(waveform: waveform, outputs: format.outputTargets(path: path))
    print("wrote \(path)")
  }

  // MARK: Helpers

  @discardableResult
  private func export(
    waveform: WaveformData,
    outputs: OutputTargets
  ) async throws -> [ArtifactReference] {
    let artifactReferencer = try CoreSpiceCLIArtifactReferencer()
    var artifacts: [ArtifactReference] = []
    if let raw = outputs.raw {
      _ = try await SPICEIO.exportToRAW(waveform, path: raw)
      artifacts.append(try artifactReferencer.output(path: raw, kind: .waveform, format: .raw))
    }
    if let csv = outputs.csv {
      _ = try await SPICEIO.exportToCSV(waveform, path: csv)
      artifacts.append(try artifactReferencer.output(path: csv, kind: .waveform, format: .csv))
    }
    if let psf = outputs.psf {
      _ = try await SPICEIO.exportToPSF(waveform, path: psf)
      artifacts.append(
        try artifactReferencer.output(
          path: psf,
          kind: .waveform,
          format: ArtifactFormat(rawValue: "psf")
        )
      )
    }
    return artifacts
  }

  @discardableResult
  private func export(
    parametric: ParametricWaveformData,
    outputs: OutputTargets
  ) async throws -> [ArtifactReference] {
    let artifactReferencer = try CoreSpiceCLIArtifactReferencer()
    var artifacts: [ArtifactReference] = []
    // Export stats to CSV if requested; otherwise export first run for RAW/PSF.
    if let csv = outputs.csv, let firstRun = parametric.runs.first {
      var lines: [String] = []
      lines.append("variable,point,mean,stdev,min,max,p5,p95")
      for variable in firstRun.waveform.variables {
        let stats = try parametric.checkedStatistics(forVariable: variable.name)
        for (idx, mean) in stats.mean.enumerated() {
          let p5 = stats.percentile5[idx]
          let p95 = stats.percentile95[idx]
          let sd = stats.standardDeviation[idx]
          let mn = stats.minimum[idx]
          let mx = stats.maximum[idx]
          lines.append("\(variable.name),\(idx),\(mean),\(sd),\(mn),\(mx),\(p5),\(p95)")
        }
      }
      try lines.joined(separator: "\n").write(toFile: csv, atomically: true, encoding: .utf8)
      artifacts.append(try artifactReferencer.output(path: csv, kind: .waveform, format: .csv))
    }

    // RAW and PSF represent one plot, so export the first parametric run.
    if let raw = outputs.raw, let first = parametric.runs.first?.waveform {
      _ = try await SPICEIO.exportToRAW(first, path: raw)
      artifacts.append(try artifactReferencer.output(path: raw, kind: .waveform, format: .raw))
    }
    if let psf = outputs.psf, let first = parametric.runs.first?.waveform {
      _ = try await SPICEIO.exportToPSF(first, path: psf)
      artifacts.append(
        try artifactReferencer.output(
          path: psf,
          kind: .waveform,
          format: ArtifactFormat(rawValue: "psf")
        )
      )
    }
    return artifacts
  }

  private func printHelp() {
    print(
      """
      Usage:
        corespice --action-domain [--json]
        corespice metric-improvement-objective --measurement-report report.json --specification spec.json --parameter-space bounds.json [--output problem.json] [--problem-id id] [--created-at timestamp] [--pretty]
        corespice convergence-recovery-objective --diagnostic-report diagnostics.json --netlist deck.cir --analysis-options options.json [--retry-policy policy.json] [--output problem.json] [--problem-id id] [--created-at timestamp] [--pretty]
        corespice -b <deck.cir> [--json] [--tran tstep tstop | --ac dec|lin points start stop | --dc source start stop step] [-r out.raw] [--csv out.csv] [--psf out.psf] [--coverage-json report.json]
        corespice measure --waveform <path.csv> --measure "<spec>" [--measure "<spec>" ...] [--json]
        corespice            # interactive shell

      JSON records:
        Batch success records contain a replayable ExecutionInvocation plus
        inputArtifacts and outputArtifacts as
        CircuiteFoundation ArtifactReference values. Each reference records
        location, role, kind, format, SHA-256 digest, byte count, and the
        producer identity for CoreSpice-generated outputs.

      Post-hoc measurement (measure):
        Evaluates .measure-grammar specs against a stored waveform CSV without
        re-simulating. <spec> is the .measure statement without the leading
        '.measure' and must start with tran|ac|dc|op, e.g.
          "tran vfinal FIND V(out) AT=5u"
        Supported kinds: FIND ... AT=, AVG, RMS, MIN, MAX, PP, INTEG
        (all with optional FROM=/TO=), RISE_TIME, FALL_TIME, TRIG/TARG delay,
        and WHEN. Other .measure kinds (e.g. DERIV, PARAM) are rejected.

      Commands (REPL):
        source <path>        Load a SPICE deck
        run                  Auto-detect .tran/.ac/.dc/.op and run
        op | tran | ac | dc  Run a specific analysis
        write raw|csv|psf <path>  Export last result
        help                 Show this message
        quit                 Exit
      """)
  }

  private func reportOptionDiagnostics(_ diagnostics: [SPICEAnalysisOptionDiagnostic]) {
    for diagnostic in diagnostics {
      fputs("warning: \(diagnostic.message)\n", stderr)
    }
  }

  private func printMeasurements(_ measurements: [SPICEMeasurementResult]) {
    for measurement in measurements {
      let suffix = measurement.unit.isEmpty ? "" : " \(measurement.unit)"
      print(
        "measure \(measurement.analysisType.rawValue) \(measurement.name)=\(measurement.value)\(suffix)"
      )
    }
  }

  private func writeCoverageReport(
    _ report: SPICEDeckCoverageReport,
    path: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

// MARK: - Session and Analysis

struct Session {
  private(set) var plan: ExecutionPlan?
  private let registry = DeviceRegistry.withOptoelectronics()
  private(set) var devices: [any BoundDevice] = []
  private(set) var lastWaveform: WaveformData?
  private(set) var lastParametric: ParametricWaveformData?
  private(set) var lastMeasurements: [SPICEMeasurementResult] = []
  private(set) var lastSource: String = ""
  private(set) var parsedNetlist: ParsedNetlist?
  private(set) var initialNodeVoltages: [Node: Double] = [:]
  private(set) var nodeSetVoltages: [Node: Double] = [:]
  private var analysisEvaluationContext = LoweringContext()
  private(set) var monteCarloSpec: MonteCarloSpec?
  private(set) var analysisOptions: SPICEAnalysisOptions = .default

  var isLoaded: Bool { plan != nil }

  mutating func loadNetlist(source: String, fileName: String?) async throws {
    let loadedDeck = try await SPICEDeckLoader.load(source: source, fileName: fileName)
    try loadNetlist(loadedDeck)
  }

  mutating func loadNetlist(
    _ loadedDeck: LoadedSPICEDeck,
    randomSeed: UInt64? = nil
  ) throws {
    lastSource = loadedDeck.source
    let netlist = loadedDeck.netlist
    parsedNetlist = netlist
    analysisEvaluationContext = try SPICEAnalysisOptions.makeEvaluationContext(from: netlist)
    analysisOptions = try SPICEAnalysisOptions.resolve(from: netlist)
    monteCarloSpec =
      netlist.analyses.compactMap { analysis in
        if case .monteCarlo(let spec) = analysis { return spec }
        return nil
      }.first

    let ir = try SPICEIO.lower(
      netlist,
      configuration: analysisOptions.loweringConfiguration(
        randomSeed: randomSeed
      )
    )
    let compiler = StandardCompiler()
    var compiled = try compiler.compile(ir: ir)
    let evaluator = ExpressionEvaluator(context: analysisEvaluationContext)
    let resolvedInitialNodeVoltages = try Self.resolveNodeVoltages(
      netlist.initialConditions,
      label: "initial condition",
      plan: compiled,
      evaluator: evaluator
    )
    let resolvedNodeSetVoltages = try Self.resolveNodeVoltages(
      netlist.nodeSets,
      label: "nodeset",
      plan: compiled,
      evaluator: evaluator
    )

    let bound = try bindDevices(plan: compiled, overrideSource: nil)

    // Build optical network graph if circuit contains optical devices
    compiled = try Self.integrateOpticalNetwork(plan: compiled, devices: bound)

    self.plan = compiled
    self.devices = bound
    self.lastWaveform = nil
    self.lastParametric = nil
    self.lastMeasurements = []
    self.initialNodeVoltages = resolvedInitialNodeVoltages
    self.nodeSetVoltages = resolvedNodeSetVoltages
  }

  mutating func run(_ command: AnalysisCommand) async throws -> WaveformData {
    guard let plan else { throw CLIError.state("no netlist loaded") }
    let cancellation = CancellationToken()
    let solver = SparseLUSolver()

    let waveform: WaveformData
    switch command {
    case .op:
      waveform = try await runOperatingPoint(plan: plan, solver: solver, cancellation: cancellation)
    case .tran(let tstep, let tstop):
      waveform = try await runTransient(
        plan: plan,
        stepTime: tstep,
        stopTime: tstop,
        solver: solver,
        cancellation: cancellation
      )
    case .ac(let sweep):
      waveform = try await runAC(
        plan: plan, sweep: sweep, solver: solver, cancellation: cancellation)
    case .dcSweep(let source, let start, let stop, let step):
      waveform = try await runDCSweep(
        plan: plan,
        source: source,
        start: start,
        stop: stop,
        step: step,
        solver: solver,
        cancellation: cancellation
      )
    }

    let measurements = try evaluateMeasurements(for: waveform)
    let projected = try SPICEOutputProjector.project(
      waveform,
      controls: parsedNetlist?.controls ?? []
    )
    self.lastWaveform = projected
    self.lastParametric = nil
    self.lastMeasurements = measurements
    return projected
  }

  private func runOperatingPoint(
    plan: ExecutionPlan,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    let result = try await DCAnalysis(
      config: analysisOptions.convergence,
      nodeInitialGuess: nodeSetVoltages
    ).run(
      plan: plan,
      devices: devices,
      solver: solver,
      observer: nil,
      cancellation: cancellation
    )
    return WaveformData.from(
      dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")
  }

  private func runTransient(
    plan: ExecutionPlan,
    stepTime: Double,
    stopTime: Double,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    guard stopTime > 0, stepTime > 0, stopTime.isFinite, stepTime.isFinite else {
      throw CLIError.invalidArguments(
        "transient analysis requires tstep > 0 and tstop > 0 (got tstep=\(stepTime), tstop=\(stopTime))"
      )
    }
    let config = try analysisOptions.transientConfig(
      stopTime: stopTime,
      stepTime: stepTime,
      startTime: nil,
      maxStep: nil,
      useInitialConditions: false,
      nodeVoltageGuesses: nodeSetVoltages
    )
    let result = try await TransientAnalysis(
      config: config,
      convergenceConfig: analysisOptions.convergence
    ).run(
      plan: plan,
      devices: devices,
      solver: solver,
      observer: nil,
      cancellation: cancellation
    )
    return try WaveformData.checkedFrom(
      transientResult: result, topology: plan.topology.circuitTopology, title: "Transient")
  }

  private func runAC(
    plan: ExecutionPlan,
    sweep: FrequencySweep,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    let result = try await ACAnalysis(sweep: sweep, dcConfig: analysisOptions.convergence).run(
      plan: plan,
      devices: devices,
      solver: solver,
      observer: nil,
      cancellation: cancellation
    )
    return WaveformData.from(acResult: result, topology: plan.topology.circuitTopology, title: "AC")
  }

  private func runDCSweep(
    plan: ExecutionPlan,
    source: String,
    start: Double,
    stop: Double,
    step: Double,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
    let values = strideInclusive(from: start, through: stop, by: step)
    try Self.validateDCSweepSource(plan: plan, source: source)
    var results: [DCResult] = []
    results.reserveCapacity(values.count)

    for value in values {
      let devices = try bindDevices(plan: plan, overrideSource: (source, value))
      let result = try await DCAnalysis(
        config: analysisOptions.convergence,
        nodeInitialGuess: nodeSetVoltages
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      results.append(result)
    }

    let sweepResult = SweepResult(parameterName: source, values: values, results: results)
    return WaveformData.from(
      sweepResult: sweepResult, topology: plan.topology.circuitTopology, title: "DC Sweep")
  }

  /// The first analysis directive from the parsed netlist that the CLI can run
  /// directly (operating point, transient, AC, or DC sweep). Monte Carlo is
  /// handled separately via `monteCarloSpec`.
  var firstRunnableAnalysis: ParsedAnalysisCommand? {
    parsedNetlist?.analyses.first { analysis in
      Self.isRunnableAnalysis(analysis)
    }
  }

  func defaultRunnableAnalysis() throws -> ParsedAnalysisCommand? {
    guard let analyses = parsedNetlist?.analyses, !analyses.isEmpty else {
      return nil
    }
    let unsupported = analyses.filter { !Self.isRunnableAnalysis($0) && !Self.isMonteCarloAnalysis($0) }
    if let firstUnsupported = unsupported.first {
      throw CLIError.unsupportedAnalysis(Self.analysisName(firstUnsupported))
    }
    return analyses.first { Self.isRunnableAnalysis($0) }
  }

  func requiredDefaultRunnableAnalysis() throws -> ParsedAnalysisCommand {
    guard let analysis = try defaultRunnableAnalysis() else {
      throw CLIError.missingAnalysisDirective
    }
    return analysis
  }

  private static func isRunnableAnalysis(_ analysis: ParsedAnalysisCommand) -> Bool {
    switch analysis {
    case .op, .transient, .ac, .dc, .noise, .transferFunction,
      .sensitivity, .poleZero, .fourier:
      return true
    case .monteCarlo:
      return false
    }
  }

  private static func isMonteCarloAnalysis(_ analysis: ParsedAnalysisCommand) -> Bool {
    if case .monteCarlo = analysis {
      return true
    }
    return false
  }

  static func analysisName(_ analysis: ParsedAnalysisCommand) -> String {
    switch analysis {
    case .op:
      return "op"
    case .dc:
      return "dc"
    case .ac:
      return "ac"
    case .transient:
      return "tran"
    case .noise:
      return "noise"
    case .transferFunction:
      return "tf"
    case .sensitivity:
      return "sens"
    case .monteCarlo:
      return "mc"
    case .poleZero:
      return "pz"
    case .fourier:
      return "four"
    }
  }

  /// Runs an analysis directive taken from the parsed netlist, reusing the
  /// parser-resolved numeric values (SPICE engineering suffixes already
  /// applied). This avoids re-parsing the raw source string in the CLI.
  mutating func runParsed(_ analysis: ParsedAnalysisCommand) async throws -> WaveformData {
    guard let plan else { throw CLIError.state("no netlist loaded") }
    let waveform = try await Self.runParsedAnalysis(
      analysis,
      plan: plan,
      devices: devices,
      registry: registry,
      options: analysisOptions,
      initialNodeVoltages: initialNodeVoltages,
      nodeSetVoltages: nodeSetVoltages,
      evaluator: ExpressionEvaluator(context: analysisEvaluationContext),
      transientSpec: parsedNetlist?.analyses.compactMap {
        if case .transient(let spec) = $0 { return spec }
        return nil
      }.first
    )
    let measurements = try evaluateMeasurements(for: waveform)
    let projected = try SPICEOutputProjector.project(
      waveform,
      controls: parsedNetlist?.controls ?? []
    )
    self.lastWaveform = projected
    self.lastParametric = nil
    self.lastMeasurements = measurements
    return projected
  }

  mutating func runMonteCarlo(
    spec: MonteCarloSpec,
    inner: ParsedAnalysisCommand,
    seedOverride: UInt64? = nil
  ) async throws -> ParametricWaveformData {
    guard let netlist = parsedNetlist else {
      throw CLIError.state("no parsed netlist for Monte Carlo")
    }
    guard spec.iterations > 0 else {
      throw CLIError.invalidArguments("Monte Carlo iterations must be positive")
    }

    var runs: [ParametricWaveformData.Run] = []
    let baseSeed = seedOverride ?? UInt64(spec.seed ?? 1)

    for i in 0..<spec.iterations {
      let seed = baseSeed &+ UInt64(i)
      let config = analysisOptions.loweringConfiguration(randomSeed: seed)
      let ir = try SPICEIO.lower(netlist, configuration: config)
      let compiler = StandardCompiler()
      let compiled = try compiler.compile(ir: ir)

      let registry = DeviceRegistry.withOptoelectronics()
      let mcStructure = compiled.matrixStructure
      var context = BindingContext(
        variableMap: compiled.topology.variableMap,
        matrixDimension: compiled.topology.dimension,
        branchNames: compiled.ir.branchNames,
        operatingConditions: try analysisOptions.operatingConditions(),
        stampIndexResolver: { row, col in mcStructure.index(row: row, col: col) }
      )
      var bound: [any BoundDevice] = []
      for instance in ir.instances {
        guard let desc = registry.descriptor(for: instance.typeName) else {
          throw CLIError.state("no descriptor for device \(instance.typeName)")
        }
        bound.append(try desc.bind(instance: instance, context: &context))
      }

      // Build optical network graph for this Monte Carlo iteration
      let mcPlan = try Self.integrateOpticalNetwork(plan: compiled, devices: bound)

      let fullWaveform = try await Self.runParsedAnalysis(
        inner,
        plan: mcPlan,
        devices: bound,
        registry: registry,
        options: analysisOptions,
        initialNodeVoltages: initialNodeVoltages,
        nodeSetVoltages: nodeSetVoltages,
        evaluator: ExpressionEvaluator(context: analysisEvaluationContext),
        transientSpec: netlist.analyses.compactMap {
          if case .transient(let spec) = $0 { return spec }
          return nil
        }.first
      )
      let measurements = try evaluateMeasurements(for: fullWaveform)
      let waveform = try SPICEOutputProjector.project(
        fullWaveform,
        controls: netlist.controls
      )
      if i == 0 {
        lastMeasurements = measurements
      }
      let run = try ParametricWaveformData.Run(
        validatingIndex: i,
        parameters: ["run": Double(i)],
        waveform: waveform
      )
      runs.append(run)
    }

    let parametric = try ParametricWaveformData(
      validatingRuns: runs,
      analysisType: runs.first?.waveform.metadata.analysisType ?? .transient,
      title: "Monte Carlo",
      parameterNames: ["run"]
    )

    self.lastParametric = parametric
    self.lastWaveform = runs.first?.waveform
    if runs.isEmpty {
      self.lastMeasurements = []
    }
    return parametric
  }

  private static func runParsedAnalysis(
    _ analysis: ParsedAnalysisCommand,
    plan: ExecutionPlan,
    devices: [any BoundDevice],
    registry: DeviceRegistry,
    options: SPICEAnalysisOptions,
    initialNodeVoltages: [Node: Double],
    nodeSetVoltages: [Node: Double],
    evaluator: ExpressionEvaluator,
    transientSpec: TransientAnalysisSpec?
  ) async throws -> WaveformData {
    let cancellation = CancellationToken()
    let solver = SparseLUSolver()

    switch analysis {
    case .op:
      return try await runParsedOperatingPoint(
        plan: plan,
        devices: devices,
        options: options,
        nodeSetVoltages: nodeSetVoltages,
        solver: solver,
        cancellation: cancellation
      )

    case .transient(let spec):
      return try await runParsedTransient(
        spec: spec,
        plan: plan,
        devices: devices,
        options: options,
        initialNodeVoltages: initialNodeVoltages,
        nodeSetVoltages: nodeSetVoltages,
        evaluator: evaluator,
        solver: solver,
        cancellation: cancellation
      )

    case .ac(let spec):
      return try await runParsedAC(
        spec: spec,
        plan: plan,
        devices: devices,
        options: options,
        evaluator: evaluator,
        solver: solver,
        cancellation: cancellation
      )

    case .dc(let spec):
      return try await runParsedDCSweep(
        spec: spec,
        plan: plan,
        registry: registry,
        options: options,
        nodeSetVoltages: nodeSetVoltages,
        evaluator: evaluator,
        solver: solver,
        cancellation: cancellation
      )

    case .noise(let spec):
      let outputNode = try resolveNode(named: spec.outputNode, plan: plan)
      let referenceNode = try spec.referenceNode.map {
        try resolveNode(named: $0, plan: plan)
      }
      let sweep = try frequencySweep(from: spec, evaluator: evaluator)
      let result = try await NoiseAnalysis(
        outputNode: outputNode,
        outputReferenceNode: referenceNode,
        inputSourceName: spec.inputSource,
        sweep: sweep,
        dcConfig: options.convergence
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      return WaveformData.from(noiseResult: result, title: "Noise")

    case .transferFunction(let spec):
      let outputNode = try resolveVoltageOutput(spec.output, plan: plan)
      let result = try await TransferFunctionAnalysis(
        outputNode: outputNode,
        inputSourceName: spec.input,
        dcConfig: options.convergence
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      return WaveformData.from(transferFunctionResult: result, title: "Transfer Function")

    case .sensitivity(let spec):
      let outputNode = try resolveVoltageOutput(spec.output, plan: plan)
      let binding = StandardCircuitDeviceBinding(
        registry: registry,
        operatingConditions: try options.operatingConditions()
      )
      if let acSpec = spec.acSpec {
        let sweep = try frequencySweep(from: acSpec, evaluator: evaluator)
        let result = try await ACSensitivityAnalysis(
          outputPositiveNode: outputNode,
          sweep: sweep,
          dcConfig: options.convergence,
          deviceBinding: binding
        ).run(
          plan: plan,
          devices: devices,
          solver: solver,
          observer: nil,
          cancellation: cancellation
        )
        return WaveformData.from(
          acSensitivityResult: result,
          title: "AC Sensitivity"
        )
      }
      let result = try await SensitivityAnalysis(
        outputNode: outputNode,
        dcConfig: options.convergence,
        deviceBinding: binding
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      return WaveformData.from(sensitivityResult: result, title: "Sensitivity")

    case .poleZero(let spec):
      let inputPositive = try resolveNode(named: spec.inputNode, plan: plan)
      let inputNegative = try resolveNode(named: spec.inputReference, plan: plan)
      let outputPositive = try resolveNode(named: spec.outputNode, plan: plan)
      let outputNegative = try resolveNode(named: spec.outputReference, plan: plan)
      let input: PoleZeroInput
      switch spec.transferType {
      case .voltage:
        input = .voltage(positive: inputPositive, reference: inputNegative)
      case .current:
        input = .current(positive: inputPositive, reference: inputNegative)
      }
      let unfiltered = try await PoleZeroAnalysis(
        input: input,
        outputPositiveNode: outputPositive,
        outputReferenceNode: outputNegative,
        dcConfig: options.convergence
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      let result = try PoleZeroResult(
        poles: spec.analysisType == .zeros ? [] : unfiltered.poles,
        zeros: spec.analysisType == .poles ? [] : unfiltered.zeros,
        dcGain: unfiltered.dcGain,
        variableMap: unfiltered.variableMap
      )
      return WaveformData.from(poleZeroResult: result, title: "Pole-Zero")

    case .fourier(let spec):
      guard let transientSpec else {
        throw CLIError.invalidArguments(
          "Fourier analysis requires a .tran directive in the same deck"
        )
      }
      let frequency = try numericValue(
        spec.frequency,
        field: "four.frequency",
        evaluator: evaluator
      )
      let outputs = try spec.outputs.map {
        try resolveFourierOutput($0, plan: plan)
      }
      let config = try makeTransientConfig(
        spec: transientSpec,
        options: options,
        initialNodeVoltages: initialNodeVoltages,
        nodeSetVoltages: nodeSetVoltages,
        evaluator: evaluator
      )
      let result = try await FourierAnalysis(
        fundamentalFrequency: frequency,
        outputs: outputs,
        transientConfig: config,
        convergenceConfig: options.convergence
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      return WaveformData.from(fourierResult: result, title: "Fourier")

    case .monteCarlo:
      // Nested Monte Carlo is not supported
      throw CLIError.state("nested Monte Carlo not supported")
    }
  }

  private static func runParsedOperatingPoint(
    plan: ExecutionPlan,
    devices: [any BoundDevice],
    options: SPICEAnalysisOptions,
    nodeSetVoltages: [Node: Double],
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    let result = try await DCAnalysis(
      config: options.convergence,
      nodeInitialGuess: nodeSetVoltages
    ).run(
      plan: plan,
      devices: devices,
      solver: solver,
      observer: nil,
      cancellation: cancellation
    )
    return WaveformData.from(
      dcResult: result, topology: plan.topology.circuitTopology, title: "Operating Point")
  }

  private static func runParsedTransient(
    spec: TransientAnalysisSpec,
    plan: ExecutionPlan,
    devices: [any BoundDevice],
    options: SPICEAnalysisOptions,
    initialNodeVoltages: [Node: Double],
    nodeSetVoltages: [Node: Double],
    evaluator: ExpressionEvaluator,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    let config = try makeTransientConfig(
      spec: spec,
      options: options,
      initialNodeVoltages: initialNodeVoltages,
      nodeSetVoltages: nodeSetVoltages,
      evaluator: evaluator
    )
    let result = try await TransientAnalysis(
      config: config,
      convergenceConfig: options.convergence
    ).run(
      plan: plan,
      devices: devices,
      solver: solver,
      observer: nil,
      cancellation: cancellation
    )
    return try WaveformData.checkedFrom(
      transientResult: result, topology: plan.topology.circuitTopology, title: "Transient")
  }

  private static func makeTransientConfig(
    spec: TransientAnalysisSpec,
    options: SPICEAnalysisOptions,
    initialNodeVoltages: [Node: Double],
    nodeSetVoltages: [Node: Double],
    evaluator: ExpressionEvaluator
  ) throws -> TransientConfig {
    let stop = try numericValue(spec.stopTime, field: "tran.tstop", evaluator: evaluator)
    guard stop > 0 else {
      throw CLIError.invalidArguments("transient analysis requires a positive stop time")
    }
    let step = try spec.stepTime.map {
      try numericValue($0, field: "tran.tstep", evaluator: evaluator)
    } ?? (stop / 50.0)
    guard step > 0 else {
      throw CLIError.invalidArguments("transient analysis requires a positive time step")
    }
    let startTime = try spec.startTime.map {
      try numericValue($0, field: "tran.tstart", evaluator: evaluator)
    }
    let maxStep = try spec.maxStep.map {
      try numericValue($0, field: "tran.tmax", evaluator: evaluator)
    }
    return try options.transientConfig(
      stopTime: stop,
      stepTime: step,
      startTime: startTime,
      maxStep: maxStep,
      useInitialConditions: spec.useInitialConditions,
      initialNodeVoltages: initialNodeVoltages,
      nodeVoltageGuesses: nodeSetVoltages
    )
  }

  private static func runParsedAC(
    spec: ACAnalysisSpec,
    plan: ExecutionPlan,
    devices: [any BoundDevice],
    options: SPICEAnalysisOptions,
    evaluator: ExpressionEvaluator,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    let sweep = try frequencySweep(from: spec, evaluator: evaluator)
    let result = try await ACAnalysis(sweep: sweep, dcConfig: options.convergence).run(
      plan: plan,
      devices: devices,
      solver: solver,
      observer: nil,
      cancellation: cancellation
    )
    return WaveformData.from(acResult: result, topology: plan.topology.circuitTopology, title: "AC")
  }

  private static func runParsedDCSweep(
    spec: DCAnalysisSpec,
    plan: ExecutionPlan,
    registry: DeviceRegistry,
    options: SPICEAnalysisOptions,
    nodeSetVoltages: [Node: Double],
    evaluator: ExpressionEvaluator,
    solver: SparseLUSolver,
    cancellation: CancellationToken
  ) async throws -> WaveformData {
    let start = try numericValue(spec.startValue, field: "dc.start", evaluator: evaluator)
    let stop = try numericValue(spec.stopValue, field: "dc.stop", evaluator: evaluator)
    let step = try numericValue(spec.stepValue, field: "dc.step", evaluator: evaluator)
    guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
    let values = strideInclusive(from: start, through: stop, by: step)
    try validateDCSweepSource(plan: plan, source: spec.source)
    var results: [DCResult] = []
    for value in values {
      let devices = try bindDevices(
        plan: plan,
        registry: registry,
        overrideSource: (spec.source, value),
        operatingConditions: try options.operatingConditions()
      )
      let result = try await DCAnalysis(
        config: options.convergence,
        nodeInitialGuess: nodeSetVoltages
      ).run(
        plan: plan,
        devices: devices,
        solver: solver,
        observer: nil,
        cancellation: cancellation
      )
      results.append(result)
    }
    let sweepResult = SweepResult(parameterName: spec.source, values: values, results: results)
    return WaveformData.from(
      sweepResult: sweepResult, topology: plan.topology.circuitTopology, title: "DC Sweep")
  }

  private static func frequencySweep(
    from spec: ACAnalysisSpec,
    evaluator: ExpressionEvaluator
  ) throws -> FrequencySweep {
    let points = spec.numberOfPoints
    let start = try numericValue(spec.startFrequency, field: "ac.start", evaluator: evaluator)
    let stop = try numericValue(spec.stopFrequency, field: "ac.stop", evaluator: evaluator)
    switch spec.scaleType {
    case .decade:
      return .decade(start: start, stop: stop, pointsPerDecade: points)
    case .octave:
      return .octave(start: start, stop: stop, pointsPerOctave: points)
    case .linear:
      return .linear(start: start, stop: stop, points: points)
    }
  }

  private static func frequencySweep(
    from spec: NoiseAnalysisSpec,
    evaluator: ExpressionEvaluator
  ) throws -> FrequencySweep {
    let start = try numericValue(
      spec.startFrequency,
      field: "noise.start",
      evaluator: evaluator
    )
    let stop = try numericValue(
      spec.stopFrequency,
      field: "noise.stop",
      evaluator: evaluator
    )
    switch spec.scaleType {
    case .decade:
      return .decade(start: start, stop: stop, pointsPerDecade: spec.numberOfPoints)
    case .octave:
      return .octave(start: start, stop: stop, pointsPerOctave: spec.numberOfPoints)
    case .linear:
      return .linear(start: start, stop: stop, points: spec.numberOfPoints)
    }
  }

  private static func resolveNode(named name: String, plan: ExecutionPlan) throws -> Node {
    let normalized = name.lowercased()
    if normalized == "0" || normalized == "gnd" {
      return plan.ir.groundNode
    }
    guard let node = plan.ir.nodeNames.first(where: {
      $0.value.caseInsensitiveCompare(name) == .orderedSame
    })?.key else {
      throw CLIError.invalidArguments("analysis references unknown node '\(name)'")
    }
    return node
  }

  private static func resolveVoltageOutput(
    _ expression: String,
    plan: ExecutionPlan
  ) throws -> Node {
    guard expression.count >= 4,
      expression.lowercased().hasPrefix("v("),
      expression.hasSuffix(")")
    else {
      throw CLIError.invalidArguments(
        "expected voltage output V(node), got '\(expression)'"
      )
    }
    return try resolveNode(named: String(expression.dropFirst(2).dropLast()), plan: plan)
  }

  private static func resolveFourierOutput(
    _ expression: String,
    plan: ExecutionPlan
  ) throws -> FourierOutput {
    if expression.lowercased().hasPrefix("v("), expression.hasSuffix(")") {
      let node = try resolveVoltageOutput(expression, plan: plan)
      return FourierOutput(variable: .nodeVoltage(node), name: expression)
    }
    if expression.lowercased().hasPrefix("i("), expression.hasSuffix(")") {
      let name = String(expression.dropFirst(2).dropLast())
      guard let branch = plan.ir.branchNames.first(where: {
        $0.value.caseInsensitiveCompare(name) == .orderedSame
      })?.key else {
        throw CLIError.invalidArguments(
          "Fourier output references unknown branch current '\(name)'"
        )
      }
      return FourierOutput(variable: .branchCurrent(branch), name: expression)
    }
    throw CLIError.invalidArguments(
      "Fourier output must be V(node) or I(device), got '\(expression)'"
    )
  }

  private static func resolveNodeVoltages(
    _ assignments: [String: ParsedParameterValue],
    label: String,
    plan: ExecutionPlan,
    evaluator: ExpressionEvaluator
  ) throws -> [Node: Double] {
    guard !assignments.isEmpty else { return [:] }

    var nodesByName: [String: Node] = [:]
    nodesByName.reserveCapacity(plan.ir.nodeNames.count + 2)
    for (node, name) in plan.ir.nodeNames {
      nodesByName[name.lowercased()] = node
    }
    nodesByName["0"] = plan.ir.groundNode
    nodesByName["gnd"] = plan.ir.groundNode

    var resolved: [Node: Double] = [:]
    for (nodeName, value) in assignments {
      let normalizedName = nodeName.lowercased()
      guard let node = nodesByName[normalizedName] else {
        throw CLIError.invalidArguments("\(label) references unknown node '\(nodeName)'")
      }
      let voltage = try numericValue(value, field: "\(label).\(nodeName)", evaluator: evaluator)
      if node == plan.ir.groundNode, voltage != 0 {
        throw CLIError.invalidArguments("\(label) for ground node must be zero")
      }
      resolved[node] = voltage
    }
    return resolved
  }

  private static func numericValue(
    _ value: ParsedParameterValue,
    field: String,
    evaluator: ExpressionEvaluator
  ) throws -> Double {
    let result: Double
    do {
      result = try evaluator.evaluate(value)
    } catch {
      throw CLIError.invalidArguments("\(field) could not be resolved: \(error.localizedDescription)")
    }
    guard result.isFinite else {
      throw CLIError.invalidArguments("\(field) must be finite, got \(result)")
    }
    return result
  }

  private func evaluateMeasurements(
    for waveform: WaveformData
  ) throws -> [SPICEMeasurementResult] {
    guard let parsedNetlist else {
      return []
    }
    let measures = parsedNetlist.controls.compactMap { control -> MeasureSpec? in
      if case .measure(let measure) = control {
        return measure
      }
      return nil
    }
    return try SPICEMeasureEvaluator().evaluate(measures: measures, waveform: waveform)
  }

  private func bindDevices(
    plan: ExecutionPlan,
    overrideSource: (String, Double)?
  ) throws -> [any BoundDevice] {
    try Self.bindDevices(
      plan: plan,
      registry: registry,
      overrideSource: overrideSource,
      operatingConditions: try analysisOptions.operatingConditions()
    )
  }

  private static func bindDevices(
    plan: ExecutionPlan,
    registry: DeviceRegistry,
    overrideSource: (String, Double)?,
    operatingConditions: OperatingConditions
  ) throws -> [any BoundDevice] {
    if let overrideSource {
      try validateDCSweepSource(plan: plan, source: overrideSource.0)
    }

    let structure = plan.matrixStructure
    var context = BindingContext(
      variableMap: plan.topology.variableMap,
      matrixDimension: plan.topology.dimension,
      branchNames: plan.ir.branchNames,
      operatingConditions: operatingConditions,
      stampIndexResolver: { row, col in structure.index(row: row, col: col) }
    )

    var devices: [any BoundDevice] = []
    devices.reserveCapacity(plan.ir.instances.count)

    let overrideName = overrideSource?.0.lowercased()
    let overrideValue = overrideSource?.1

    for instance in plan.ir.instances {
      let inst: Instance
      if let overrideName, let overrideValue, instance.name.lowercased() == overrideName {
        var params = instance.parameters
        switch instance.typeName.lowercased() {
        case "vsource":
          params["v"] = .real(overrideValue)
        case "isource":
          params["i"] = .real(overrideValue)
        default:
          throw CLIError.invalidArguments(
            "dc sweep source '\(instance.name)' must be an independent voltage or current source, got \(instance.typeName)"
          )
        }
        inst = Instance(
          name: instance.name,
          typeName: instance.typeName,
          nodes: instance.nodes,
          parameters: params
        )
      } else {
        inst = instance
      }

      guard let desc = registry.descriptor(for: inst.typeName) else {
        throw CLIError.state("no descriptor for device \(inst.typeName)")
      }
      devices.append(try desc.bind(instance: inst, context: &context))
    }

    return devices
  }

  private static func validateDCSweepSource(plan: ExecutionPlan, source: String) throws {
    let normalized = source.lowercased()
    let matches = plan.ir.instances.filter { $0.name.lowercased() == normalized }
    guard !matches.isEmpty else {
      throw CLIError.invalidArguments("dc sweep source '\(source)' was not found")
    }
    guard matches.count == 1 else {
      throw CLIError.invalidArguments("dc sweep source '\(source)' matches multiple instances")
    }
    let instance = matches[0]
    switch instance.typeName.lowercased() {
    case "vsource", "isource":
      return
    default:
      throw CLIError.invalidArguments(
        "dc sweep source '\(source)' must be an independent voltage or current source, got \(instance.typeName)"
      )
    }
  }

  /// Builds the optical network graph from bound devices and returns
  /// an updated execution plan. If no optical devices are present,
  /// returns the original plan unchanged.
  private static func integrateOpticalNetwork(
    plan: ExecutionPlan,
    devices: [any BoundDevice]
  ) throws -> ExecutionPlan {
    let graphBuilder = OpticalNetworkGraphBuilder()
    guard let graph = try graphBuilder.build(from: plan.ir, devices: devices) else {
      return plan
    }
    return ExecutionPlan(
      ir: plan.ir,
      topology: plan.topology,
      matrixStructure: plan.matrixStructure,
      deviceNames: plan.deviceNames,
      opticalNetwork: graph
    )
  }
}

enum AnalysisCommand {
  case op
  case tran(tstep: Double, tstop: Double)
  case ac(sweep: FrequencySweep)
  case dcSweep(source: String, start: Double, stop: Double, step: Double)
}

struct OutputTargets {
  var raw: String?
  var csv: String?
  var psf: String?
  var coverageJSON: String?
}

enum CLIError: LocalizedError {
  case invalidArguments(String)
  case unknownCommand(String)
  case state(String)
  case unsupportedAnalysis(String)
  case missingAnalysisDirective

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let msg): return msg
    case .unknownCommand(let cmd): return "unknown command: \(cmd)"
    case .state(let msg): return msg
    case .unsupportedAnalysis(let analysis): return "unsupported analysis directive: \(analysis)"
    case .missingAnalysisDirective:
      return "no analysis directive found; add an explicit .op, .dc, .ac, or .tran directive"
    }
  }
}

// MARK: - Utilities

/// Parses a single SPICE-formatted number, supporting engineering suffixes such
/// as `p`, `n`, `u`, `meg`, by reusing the SPICE lexer. Returns nil when the
/// string does not yield a numeric token so callers can fail loudly instead of
/// silently substituting a default value (which previously produced wrong stop
/// times and NaN-driven crashes in the analysis setup).
func parseSPICENumber(_ string: String) -> Double? {
  guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return nil
  }
  var lexer = SPICELexer(source: string)
  let tokens = lexer.tokenize().map(\.token).filter { token in
    switch token {
    case .endOfFile, .newline:
      return false
    default:
      return true
    }
  }
  if tokens.count == 1, case .number(let value) = tokens[0] {
    guard value.isFinite else { return nil }
    return value
  }
  if tokens.count == 2 {
    switch (tokens[0], tokens[1]) {
    case (.plus, .number(let value)), (.continuation, .number(let value)):
      guard value.isFinite else { return nil }
      return value
    case (.minus, .number(let value)):
      guard value.isFinite else { return nil }
      return -value
    default:
      return nil
    }
  }
  return nil
}

private func strideInclusive(from start: Double, through stop: Double, by step: Double) -> [Double]
{
  guard step != 0 else { return [] }
  var values: [Double] = []
  var current = start
  if step > 0 {
    while current <= stop + step * 0.5 {
      values.append(current)
      current += step
    }
  } else {
    while current >= stop + step * 0.5 {
      values.append(current)
      current += step
    }
  }
  return values
}
