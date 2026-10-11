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
import CoreSpiceMOSContracts
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
    if args.first == "prepared" {
      let output = try await CoreSpicePreparedCommand(arguments: Array(args.dropFirst())).execute()
      print("input=\(output.sourceInputIdentity.hexadecimalValue) configuration=\(output.configurationIdentity.hexadecimalValue) points=\(output.waveform.pointCount) iterations=\(output.statistics.newtonIterations)")
      return
    }
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
    var session = try Session(policy: .developerV1())
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
    var session = try Session(policy: .developerV1(profile: options.profile, seed: options.randomSeed ?? 1))
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
    guard session.policy.profile == options.profile else {
      throw CLIError.invalidArguments("batch profile differs from the explicit Session policy")
    }
    let loadedDeck = try await SPICEDeckLoader.loadFile(at: options.deckPath)
    let artifactReferencer = try CoreSpiceCLIArtifactReferencer()
    let inputArtifacts = loadedDeck.captures.map { capture in
      artifactReferencer.input(capture: capture, kind: .netlist, format: .spice)
    }
    let executableCapture = try options.caseOutput.map { _ in try CoreSpiceCLICasePublisher.captureExecutable() }
    var outputArtifacts: [ArtifactReference] = []
    if let coveragePath = options.outputs.coverageJSON {
      try writeCoverageReport(loadedDeck.coverage, path: coveragePath)
      outputArtifacts.append(
        try artifactReferencer.output(path: coveragePath, kind: .report, format: .json)
      )
    }
    try session.loadNetlist(loadedDeck, randomSeed: options.randomSeed)
    if options.caseOutput != nil { session.phaseCollector = try CoreSpiceCLIPhaseCollector() }
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
    if let directory = options.caseOutput, let caseID = options.caseID, let phases = session.phaseCollector {
      outputArtifacts += try CoreSpiceCLICasePublisher().publish(directory: directory, caseID: caseID,
        loadedDeck: loadedDeck, phases: phases, referencer: artifactReferencer, executableCapture: executableCapture)
    }
    return CoreSpiceCLIBatchRunRecord(
      producer: artifactReferencer.producer,
      resolutionProfile: session.policy.profile.rawValue,
      resolutionSeed: options.randomSeed ?? session.monteCarloSpec?.seed.map(UInt64.init) ?? session.policy.seed,
      resolutionPolicy: "corespice-cli-developer-v1",
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
      waveform: waveformSummary,
      bsim4PreparationPolicy: session.analysisOptions.bsim4PreparationPolicy,
      bsim4NoisePreparationRequested: session.analysisOptions.bsim4NoisePreparationRequested,
      bsim4Models: session.completedBSIM4Models,
      bsim45Models: session.completedBSIM45Models
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
        corespice prepared <root.cir> [--mos-profile profile] [--seed seed] [--source key path] [--include parent route child] [--library parent route child section]
        corespice --action-domain [--json]
        corespice metric-improvement-objective --measurement-report report.json --specification spec.json --parameter-space bounds.json [--output problem.json] [--problem-id id] [--created-at timestamp] [--pretty]
        corespice convergence-recovery-objective --diagnostic-report diagnostics.json --netlist deck.cir --analysis-options options.json [--retry-policy policy.json] [--output problem.json] [--problem-id id] [--created-at timestamp] [--pretty]
        corespice -b <deck.cir> [--json] [--mos-profile profile] [--seed seed] [--tran tstep tstop | --ac dec|lin points start stop | --dc source start stop step] [-r out.raw] [--csv out.csv] [--psf out.psf] [--coverage-json report.json] [--case-output new-directory --case-id id]
        corespice measure --waveform <path.csv> --measure "<spec>" [--measure "<spec>" ...] [--json]
        corespice            # interactive shell

      Transient resource policy:
        A complete source .options policy overrides the selected finite developer policy:
        tranmaxaccepted, tranmaxattempts, tranmaxiterations, tranmaxscalars,
        tranmaxdimension, tranmaxwork, tranmaxbreakpoints. Values are positive
        integers; saved scalars include times and all MNA variables. Work units
        are size-weighted operation counts, not wall time or measured FLOPS.

      Source evaluation policy:
        --mos-profile coreStrictV1|pinnedNgspiceNormalV1 selects explicit MOS input semantics.
        The named developerV1 policy selects pinnedNgspiceNormalV1 and seed 1 unless overridden
        by --mos-profile or --seed. Monte Carlo uses a new scalar session per seed.
        Resolution admits 8192 elements, depth 64, 16 MiB retained source evaluation,
        1 MiB diagnostics and 1e9 evaluation steps. Native preparation admits 256 MNA
        dimensions and 64 MiB, with 1 MiB retained/temporary storage per MOS owner.
        Invocation resources admit 128 MiB live, 64 MiB temporary and 1e9 logical work.
        Exceeding these selected ceilings fails; they do not guarantee wall time or qualification.

      Native BSIM4 preparation policy:
        Level 54 exact 4.8.3 requires .options bsim4stressiterations=<positive UInt32>.
        This bounds original stress preprocessing and is retained in JSON run records.
        Parsed .noise intent prepares the original noise-dependent private topology.

      Canonical case output:
        --case-output publishes exact captured inputs, executable, model receipts,
        execution.json and availability.json in a new directory. Completed phase
        observations retain actual DC points and Monte Carlo seeds. This emits
        original evidence; it does not issue qualification. Sensitivity case output
        is refused until complete perturbation evidence is available.

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
  let policy: CoreSpiceCLIExecutionPolicy
  var phaseCollector: CoreSpiceCLIPhaseCollector?
  private(set) var plan: ExecutionPlan?
  private(set) var resolved: CoreSpiceCLIResolvedCircuit?
  private(set) var lastWaveform: WaveformData?
  private(set) var lastParametric: ParametricWaveformData?
  private(set) var lastMeasurements: [SPICEMeasurementResult] = []
  private(set) var lastSource = ""
  private(set) var completedBSIM45Models: [CoreSpiceCLIBSIM45Record] = []
  private(set) var completedBSIM4Models: [CoreSpiceCLIBSIM4Record] = []
  private var compiled: CompiledNetlist?
  private var loadedSeed: UInt64
  var parsedNetlist: ParsedNetlist? { compiled?.source }
  var analysisOptions: SPICEAnalysisOptions { resolved?.options ?? .default }
  var monteCarloSpec: MonteCarloSpec? {
    parsedNetlist?.analyses.compactMap { if case .monteCarlo(let spec) = $0 { return spec }; return nil }.first
  }
  var isLoaded: Bool { compiled != nil }

  init(policy: CoreSpiceCLIExecutionPolicy) { self.policy = policy; loadedSeed = policy.seed }

  mutating func loadNetlist(source: String, fileName: String?) async throws {
    try loadNetlist(try await SPICEDeckLoader.load(source: source, fileName: fileName))
  }

  mutating func loadNetlist(_ deck: LoadedSPICEDeck, randomSeed: UInt64? = nil) throws {
    let candidate = try NetlistLowering.compile(deck.netlist, limits: policy.resolutionLimits,
      control: CoreSpiceCLIResolutionControl(resources: policy.resources(), cancellation: nil))
    let seed = randomSeed ?? policy.seed
    let values = try CoreSpiceCLIResolvedCircuit.resolve(candidate, policy: policy,
      seed: seed, selectedAnalysisIndex: nil)
    // Publish only a complete immutable source evaluation; failed replacement keeps the prior deck.
    compiled = candidate; resolved = values; loadedSeed = seed; lastSource = deck.source
    plan = nil; phaseCollector = nil; lastWaveform = nil; lastParametric = nil
    lastMeasurements = []; completedBSIM4Models = []; completedBSIM45Models = []
  }

  mutating func run(_ command: AnalysisCommand, cancellation: CancellationToken = CancellationToken()) async throws -> WaveformData {
    let analysis: ParsedAnalysisCommand
    switch command {
    case .op: analysis = .op
    case .tran(let step, let stop): analysis = .transient(.init(stopTime: .numeric(stop), stepTime: .numeric(step)))
    case .ac(let sweep):
      return try await runExplicitAC(sweep, cancellation: cancellation)
    case .dcSweep(let source, let start, let stop, let step):
      analysis = .dc(.init(source: source, startValue: .numeric(start), stopValue: .numeric(stop), stepValue: .numeric(step)))
    }
    guard let compiled else { throw CLIError.state("no netlist loaded") }
    try beginRun()
    let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
      seed: loadedSeed, selectedAnalysisIndex: nil, cancellation: cancellation)
    resolved = values
    let waveform = try await execute(analysis, values: values, phasePrefix: "", cancellation: cancellation)
    return try finish(waveform, controls: compiled.source.controls)
  }

  private mutating func runExplicitAC(_ sweep: FrequencySweep, cancellation: CancellationToken) async throws -> WaveformData {
    guard let compiled else { throw CLIError.state("no netlist loaded") }
    try beginRun()
    let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
      seed: loadedSeed, selectedAnalysisIndex: nil, cancellation: cancellation)
    resolved = values
    let owner = try prepare(values, capabilities: [.dc, .ac])
    let record = owner.record
    let run = try await ACAnalysis(sweep: sweep, dcConfig: values.options.convergence).run(
      circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: cancellation)
    let waveform = WaveformData.from(acResult: run.result, topology: record.plan.topology.circuitTopology, title: "AC")
    try retain(run.phases, record: record, waveform: waveform, prefix: "")
    return try finish(waveform, controls: compiled.source.controls)
  }

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

  mutating func runParsed(_ analysis: ParsedAnalysisCommand) async throws -> WaveformData {
    guard let compiled, let index = compiled.source.analyses.firstIndex(of: analysis) else {
      throw CLIError.state("analysis is outside the loaded source")
    }
    try beginRun()
    let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
      seed: loadedSeed, selectedAnalysisIndex: index)
    resolved = values
    let waveform = try await execute(values.analyses[index], values: values,
      phasePrefix: "", cancellation: CancellationToken())
    return try finish(waveform, controls: compiled.source.controls)
  }

  mutating func runMonteCarlo(spec: MonteCarloSpec, inner: ParsedAnalysisCommand,
                             seedOverride: UInt64? = nil) async throws -> ParametricWaveformData {
    guard let compiled, let index = compiled.source.analyses.firstIndex(where: {
      if case .monteCarlo(let candidate) = $0 { return candidate == spec }; return false
    }), inner == spec.analysis else { throw CLIError.state("Monte Carlo is outside the loaded source") }
    guard spec.iterations > 0, spec.iterations <= policy.maximumElements else {
      throw CLIError.invalidArguments("Monte Carlo iteration budget exceeded")
    }
    if phaseCollector != nil, spec.iterations > 10_000 {
      throw CoreSpiceCLICaseError.incompleteOutput("Monte Carlo phase budget exceeded")
    }
    try beginRun()
    var runs: [ParametricWaveformData.Run] = []
    var firstMeasurements: [SPICEMeasurementResult] = []
    let seed = seedOverride ?? spec.seed.map(UInt64.init) ?? loadedSeed
    for iteration in 0..<spec.iterations {
      let (runSeed, overflow) = seed.addingReportingOverflow(UInt64(iteration))
      guard !overflow else { throw CLIError.invalidArguments("Monte Carlo seed overflow") }
      let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
        seed: runSeed, selectedAnalysisIndex: index)
      guard case .monteCarlo(let selected) = values.analyses[index] else {
        throw CLIError.state("resolved Monte Carlo shape changed")
      }
      resolved = values
      let prefix = "mc-seed:\(runSeed):"
      let waveform = try await execute(selected.analysis, values: values,
        phasePrefix: prefix, cancellation: CancellationToken())
      let measurements = try evaluateMeasurements(for: waveform)
      try phaseCollector?.measurements(measurements, prefix: prefix,
        phaseIDs: phaseCollector?.phases.filter { $0.id.hasPrefix(prefix) }.map(\.id) ?? [])
      if iteration == 0 { firstMeasurements = measurements }
      runs.append(try .init(validatingIndex: iteration, parameters: ["run": Double(iteration)],
        waveform: SPICEOutputProjector.project(waveform, controls: compiled.source.controls)))
    }
    let result = try ParametricWaveformData(validatingRuns: runs,
      analysisType: runs.first?.waveform.metadata.analysisType ?? .transient,
      title: "Monte Carlo", parameterNames: ["run"])
    phaseCollector?.finish(); lastParametric = result; lastWaveform = runs.first?.waveform
    lastMeasurements = firstMeasurements
    return result
  }

  private mutating func beginRun() throws {
    phaseCollector = try phaseCollector?.emptyCopy()
    lastWaveform = nil; lastParametric = nil; lastMeasurements = []; completedBSIM4Models = []; completedBSIM45Models = []
  }

  private mutating func finish(_ waveform: WaveformData, controls: [ParsedControlStatement]) throws -> WaveformData {
    let measurements = try evaluateMeasurements(for: waveform)
    let projected = try SPICEOutputProjector.project(waveform, controls: controls)
    try phaseCollector?.measurements(measurements, prefix: "", phaseIDs: phaseCollector?.phases.map(\.id) ?? [])
    phaseCollector?.finish(); lastWaveform = projected; lastParametric = nil; lastMeasurements = measurements
    return projected
  }

  private func prepare(_ values: CoreSpiceCLIResolvedCircuit, capabilities: MOSAnalysisCapabilities) throws -> PreparedNativeCircuit {
    let options = values.options
    guard !options.executionLimitOptionsPresent || options.executionLimits != nil else {
      throw CLIError.invalidArguments("execution policy is incomplete")
    }
    let conditions = try options.operatingConditions()
    var requestedCapabilities = capabilities
    if options.bsim4NoisePreparationRequested { requestedCapabilities.formUnion([.ac, .noise]) }
    var registry = options.deviceRegistry(); registry.registerOptoelectronicDevices()
    if options.bsim4PreparationPolicy == nil,
       let model = values.lowered.circuit.instances.first(where: {
         if case .resolved(let selected) = $0.mos { return selected.release == .bsim4_4_8_3 }; return false
       }) { throw BSIM4DeviceError.missingPreparationPolicy(model.name) }
    let stress = options.bsim4PreparationPolicy?.maximumStressIterations ?? 1
    let numericalLimits = options.executionLimits ?? policy.numericalLimits
    return try NativeCircuitPreparer().prepare(ir: values.lowered.circuit, registry: registry,
      operatingConditions: conditions,
      limits: .init(maximumDeviceCount: policy.maximumElements, maximumMatrixDimension: numericalLimits.maximumMatrixDimension,
        maximumAllocationBytes: policy.maximumAllocationBytes, mosPreparationLimits: policy.preparationLimits,
        mosPreparationConditions: try .init(ambientKelvin: conditions.temperatureKelvin,
          nominalKelvin: conditions.nominalTemperatureKelvin, analysisCapabilities: requestedCapabilities,
          maximumStressIterations: stress)),
      numericalLimits: numericalLimits, resources: values.resources)
  }

  private mutating func retain(_ phases: [NativeCircuitExecutionFacts], record: NativeCircuitPreparationRecord,
                               waveform: WaveformData, prefix: String, collectPhases: Bool = true) throws {
    plan = record.plan
    for (index, facts) in phases.enumerated() {
      let phaseID: String
      if let source = facts.sourceName, let value = facts.sourceValue {
        phaseID = "\(prefix)dc:\(source):point:\(index):value:\(value)"
      } else { phaseID = prefix + facts.analysis }
      if collectPhases {
        try phaseCollector?.record(id: phaseID, facts: facts,
          compiled: recordCompiled(), waveform: waveform)
      }
      completedBSIM45Models += record.bsim45Models.map {
        .init(phase: phaseID, device: $0.device, implementationIdentity: $0.implementationIdentity,
          diagnostics: $0.diagnostics)
      }
      completedBSIM4Models += record.bsim4Models.map {
        .init(phase: phaseID, device: $0.device, diagnostics: $0.diagnostics,
          maintainerUnsupportedNoiseMode: $0.maintainerUnsupportedNoiseMode)
      }
    }
  }

  private func recordCompiled() throws -> CompiledNetlist {
    guard let compiled else { throw CLIError.state("missing compiled source evidence") }; return compiled
  }

  private mutating func execute(_ analysis: ParsedAnalysisCommand, values: CoreSpiceCLIResolvedCircuit,
                                phasePrefix: String, cancellation: CancellationToken) async throws -> WaveformData {
    if phaseCollector != nil, case .sensitivity = analysis,
       !values.lowered.circuit.instances.contains(where: { $0.mos != nil }) {
      // FIXME(INCOMPLETE_IMPLEMENTATION): CLI case publication cannot represent sensitivity perturbation receipts.
      // The production branch refuses until every completed perturbation has exact source-bound evidence.
      throw CoreSpiceCLICaseError.unsupportedAnalysis("sensitivity")
    }
    let options = values.options
    let capabilities: MOSAnalysisCapabilities
    switch analysis {
    case .transient, .fourier: capabilities = [.dc, .transient]
    case .noise: capabilities = [.dc, .ac, .noise]
    case .ac, .poleZero: capabilities = [.dc, .ac]
    case .sensitivity(let spec): capabilities = spec.acSpec == nil ? [.dc] : [.dc, .ac]
    default: capabilities = [.dc]
    }
    let owner = try prepare(values, capabilities: capabilities)
    let record = owner.record
    let plan = record.plan
    let solver = SparseLUSolver()
    let waveform: WaveformData
    let phases: [NativeCircuitExecutionFacts]
    switch analysis {
    case .op:
      let run = try await DCAnalysis(config: options.convergence, nodeInitialGuess: values.nodeSetVoltages)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = .from(dcResult: run.result, topology: plan.topology.circuitTopology, title: "Operating Point"); phases = run.phases
    case .transient(let spec):
      let config = try Self.makeTransientConfig(spec: spec, values: values, limits: policy.numericalLimits)
      let run = try await TransientAnalysis(config: config, convergenceConfig: options.convergence)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = try .checkedFrom(transientResult: run.result, topology: plan.topology.circuitTopology, title: "Transient"); phases = run.phases
    case .ac(let spec):
      let run = try await ACAnalysis(sweep: Self.frequencySweep(from: spec), dcConfig: options.convergence)
        .run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: cancellation)
      waveform = .from(acResult: run.result, topology: plan.topology.circuitTopology, title: "AC"); phases = run.phases
    case .dc(let spec):
      guard spec.source2 == nil else { throw CLIError.unsupportedAnalysis("nested dc") }
      let start = try Self.numericValue(spec.startValue, field: "dc.start")
      let stop = try Self.numericValue(spec.stopValue, field: "dc.stop")
      let step = try Self.numericValue(spec.stepValue, field: "dc.step")
      guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
      let schedule = try strideInclusive(from: start, through: stop, by: step,
        maximumCount: min(policy.maximumElements, phaseCollector == nil ? policy.maximumElements : 10_000))
      let collector = phaseCollector
      let source = spec.source
      let compiled = try recordCompiled()
      let run = try await DCAnalysis(config: options.convergence, nodeInitialGuess: values.nodeSetVoltages)
        .runSweep(circuit: owner, source: source, values: schedule, solver: solver, observer: nil,
          cancellation: cancellation, onPointCompleted: { index, value, facts, result in
            try collector?.record(id: "\(phasePrefix)dc:\(source):point:\(index):value:\(value)",
              facts: facts, compiled: compiled,
              waveform: .from(dcResult: result, topology: plan.topology.circuitTopology, title: "DC Point"))
          })
      waveform = .from(sweepResult: run.result, topology: plan.topology.circuitTopology, title: "DC Sweep")
      phases = run.phases
    case .noise(let spec):
      let output = try Self.resolveNode(named: spec.outputNode, plan: plan)
      let reference = try spec.referenceNode.map { try Self.resolveNode(named: $0, plan: plan) }
      let run = try await NoiseAnalysis(outputNode: output, outputReferenceNode: reference,
        inputSourceName: spec.inputSource, sweep: Self.frequencySweep(from: spec), dcConfig: options.convergence)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = .from(noiseResult: run.result, title: "Noise"); phases = run.phases
    case .transferFunction(let spec):
      let run = try await TransferFunctionAnalysis(outputNode: Self.resolveVoltageOutput(spec.output, plan: plan),
        inputSourceName: spec.input, dcConfig: options.convergence)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = .from(transferFunctionResult: run.result, title: "Transfer Function"); phases = run.phases
    case .sensitivity(let spec):
      let binding = StandardCircuitDeviceBinding(registry: options.deviceRegistry(),
        operatingConditions: try options.operatingConditions())
      let output = try Self.resolveVoltageOutput(spec.output, plan: plan)
      if let ac = spec.acSpec {
        let run = try await ACSensitivityAnalysis(outputPositiveNode: output, sweep: Self.frequencySweep(from: ac),
          dcConfig: options.convergence, deviceBinding: binding)
          .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
        waveform = .from(acSensitivityResult: run.result, title: "AC Sensitivity"); phases = run.phases
      } else {
        let run = try await SensitivityAnalysis(outputNode: output, dcConfig: options.convergence, deviceBinding: binding)
          .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
        waveform = .from(sensitivityResult: run.result, title: "Sensitivity"); phases = run.phases
      }
    case .poleZero(let spec):
      let positive = try Self.resolveNode(named: spec.inputNode, plan: plan)
      let negative = try Self.resolveNode(named: spec.inputReference, plan: plan)
      let input: PoleZeroInput = spec.transferType == .voltage ? .voltage(positive: positive, reference: negative) : .current(positive: positive, reference: negative)
      let run = try await PoleZeroAnalysis(input: input,
        outputPositiveNode: Self.resolveNode(named: spec.outputNode, plan: plan),
        outputReferenceNode: Self.resolveNode(named: spec.outputReference, plan: plan), dcConfig: options.convergence)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      let filtered = try PoleZeroResult(poles: spec.analysisType == .zeros ? [] : run.result.poles,
        zeros: spec.analysisType == .poles ? [] : run.result.zeros, dcGain: run.result.dcGain, variableMap: run.result.variableMap)
      waveform = .from(poleZeroResult: filtered, title: "Pole-Zero"); phases = run.phases
    case .fourier(let spec):
      guard let transient = values.analyses.compactMap({ if case .transient(let value) = $0 { return value }; return nil }).first else {
        throw CLIError.invalidArguments("Fourier analysis requires a .tran directive in the same deck")
      }
      let run = try await FourierAnalysis(fundamentalFrequency: Self.numericValue(spec.frequency, field: "four.frequency"),
        outputs: spec.outputs.map { try Self.resolveFourierOutput($0, plan: plan) },
        transientConfig: Self.makeTransientConfig(spec: transient, values: values, limits: policy.numericalLimits),
        convergenceConfig: options.convergence).run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = .from(fourierResult: run.result, title: "Fourier"); phases = run.phases
    case .monteCarlo: throw CLIError.state("nested Monte Carlo not supported")
    }
    let collectPhases: Bool
    if case .dc = analysis { collectPhases = false } else { collectPhases = true }
    try retain(phases, record: record, waveform: waveform, prefix: phasePrefix, collectPhases: collectPhases)
    return waveform
  }

  private static func makeTransientConfig(spec: TransientAnalysisSpec, values: CoreSpiceCLIResolvedCircuit,
                                          limits: TransientExecutionLimits) throws -> TransientConfig {
    let stop = try numericValue(spec.stopTime, field: "tran.tstop")
    let step = try spec.stepTime.map { try numericValue($0, field: "tran.tstep") } ?? stop / 50
    guard stop > 0, step > 0 else { throw CLIError.invalidArguments("transient analysis requires positive times") }
    var options = values.options
    // A partial source policy must fail; only an absent policy uses the explicitly selected caller policy.
    guard !options.executionLimitOptionsPresent || options.executionLimits != nil else {
      throw CLIError.invalidArguments("transient execution policy is incomplete")
    }
    if options.executionLimits == nil { options.executionLimits = limits }
    return try options.transientConfig(stopTime: stop, stepTime: step,
      startTime: spec.startTime.map { try numericValue($0, field: "tran.tstart") },
      maxStep: spec.maxStep.map { try numericValue($0, field: "tran.tmax") },
      useInitialConditions: spec.useInitialConditions, initialNodeVoltages: values.initialNodeVoltages,
      nodeVoltageGuesses: values.nodeSetVoltages)
  }

  private static func frequencySweep(
    from spec: ACAnalysisSpec
  ) throws -> FrequencySweep {
    let points = spec.numberOfPoints
    let start = try numericValue(spec.startFrequency, field: "ac.start")
    let stop = try numericValue(spec.stopFrequency, field: "ac.stop")
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
    from spec: NoiseAnalysisSpec
  ) throws -> FrequencySweep {
    let start = try numericValue(
      spec.startFrequency,
      field: "noise.start"
    )
    let stop = try numericValue(
      spec.stopFrequency,
      field: "noise.stop"
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

  private static func numericValue(_ value: ParsedParameterValue, field: String) throws -> Double {
    guard case .numeric(let result) = value, result.isFinite else {
      throw CLIError.invalidArguments("\(field) is not a resolved finite scalar")
    }
    return result
  }

  private func evaluateMeasurements(for waveform: WaveformData) throws -> [SPICEMeasurementResult] {
    let measures = parsedNetlist?.controls.compactMap { control -> MeasureSpec? in
      if case .measure(let measure) = control { return measure }; return nil
    } ?? []
    return try SPICEMeasureEvaluator().evaluate(measures: measures, waveform: waveform)
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

private func strideInclusive(from start: Double, through stop: Double, by step: Double,
                             maximumCount: Int? = nil) throws -> [Double]
{
  guard step != 0 else { return [] }
  if let maximumCount {
    let span = (stop - start) / step
    guard start.isFinite, stop.isFinite, step.isFinite, span.isFinite,
          span >= 0, span < Double(maximumCount) else {
      throw CoreSpiceCLICaseError.incompleteOutput("DC phase budget exceeded or invalid schedule")
    }
  }
  var values: [Double] = []
  var current = start
  if step > 0 {
    while current <= stop + step * 0.5 {
      if let maximumCount, values.count >= maximumCount {
        throw CoreSpiceCLICaseError.incompleteOutput("DC phase budget exceeded")
      }
      values.append(current)
      let next = current + step
      if maximumCount != nil, next == current { throw CoreSpiceCLICaseError.incompleteOutput("DC schedule cannot advance") }
      current = next
    }
  } else {
    while current >= stop + step * 0.5 {
      if let maximumCount, values.count >= maximumCount {
        throw CoreSpiceCLICaseError.incompleteOutput("DC phase budget exceeded")
      }
      values.append(current)
      let next = current + step
      if maximumCount != nil, next == current { throw CoreSpiceCLICaseError.incompleteOutput("DC schedule cannot advance") }
      current = next
    }
  }
  return values
}
