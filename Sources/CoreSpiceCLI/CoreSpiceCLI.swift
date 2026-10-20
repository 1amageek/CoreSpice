import CoreSpice
import CoreSpiceAnalysis
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
import CoreSpiceDiodeContracts
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
      let failure = CoreSpiceCLIFailure(error: error)
      guard jsonMode else {
        fputs("error: \(failure.code): \(failure.message)\n", stderr)
        return 1
      }
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
      let completed = try await CoreSpicePreparedCommand(arguments: Array(args.dropFirst())).executeWithRecord()
      let output = completed.output
      defer { withExtendedLifetime(completed.serializationReservation) {} }
      if args.contains("--json") { print(try completed.serializedPrecisionJSON ?? CoreSpiceCLIJSON.encode(completed.record)) }
      else {
        if let cases = completed.record.cases {
          print("input=\(completed.record.sourceInputIdentity) configuration=\(completed.record.configurationIdentity) cases=\(cases.count) points=\(completed.record.points) iterations=\(completed.record.newtonIterations)")
        } else {
          print("input=\(output.sourceInputIdentity.hexadecimalValue) configuration=\(output.configurationIdentity.hexadecimalValue) points=\(output.waveform.pointCount) iterations=\(output.statistics.newtonIterations)")
        }
      }
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
    var session = try Session(policy: .developerV1(profile: options.profile, seed: options.randomSeed ?? 1, diodeProfile: options.diodeProfile))
    let completed = try await executeBatchWithJSON(options: options, session: &session)
    defer { withExtendedLifetime(completed.serializationReservation) {} }
    if options.jsonOutput {
      print(try completed.serializedJSON ?? CoreSpiceCLIJSON.encode(completed.record))
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
    try await executeBatchWithJSON(options: options, session: &session).record
  }

  private func executeBatchWithJSON(options: CoreSpiceBatchOptions, session: inout Session) async throws
    -> (record: CoreSpiceCLIBatchRunRecord, serializedJSON: String?, serializationReservation: SPICESourceStorageReservation?) {
    guard session.policy.profile == options.profile, session.policy.diodeProfile == options.diodeProfile else {
      throw CLIError.invalidArguments("batch profile differs from the explicit Session policy")
    }
    let osdiCatalog = try options.osdiCatalogPath.map { try CoreSpiceCLIOSDICatalog.load(path: $0) }
    if options.pairedCSVPath != nil && osdiCatalog?.executionBudget == nil {
      throw CoreSpiceCLIOSDIError.unsupportedAnalysis("paired CSV requires explicit precision transient input")
    }
    var effectivePolicy = session.policy
    if let path = options.executionProfilePath {
      guard !session.isLoaded else { throw CLIError.invalidArguments("An execution profile requires a fresh batch invocation") }
      let selected = try CoreSpiceCLIExecutionProfile.load(path: path)
      effectivePolicy = try effectivePolicy.applying(selected.profile, reference: selected.reference)
    }
    effectivePolicy = try effectivePolicy.applying(osdiCatalog?.executionBudget)
    if effectivePolicy.executionProfile != nil { session = Session(policy: effectivePolicy) }
    let capturePolicy: SPICESourceCapturePolicy
    if let budget = osdiCatalog?.executionBudget {
      guard options.overrideAnalysis == nil, options.outputs.raw == nil, options.outputs.psf == nil else {
        throw CoreSpiceCLIOSDIError.unsupportedAnalysis("precision batch consumes the source transient and JSON/CSV outputs")
      }
      capturePolicy = try .init(maximumTotalByteCount: min(budget.maximumLiveOwnedBytes, budget.maximumTemporaryBytes),
        maximumSourceCount: UInt64(effectivePolicy.maximumElements), maximumPageByteCount: min(4096, budget.maximumTemporaryBytes))
    } else if effectivePolicy.executionProfile != nil {
      capturePolicy = try .init(maximumTotalByteCount: effectivePolicy.maximumSourceBytes,
        maximumSourceCount: UInt64(effectivePolicy.maximumElements),
        maximumPageByteCount: min(4096, effectivePolicy.maximumSourceBytes))
    } else { capturePolicy = .hostDefault }
    let loadedDeck = try await SPICEDeckLoader.loadFile(at: options.deckPath, capturePolicy: capturePolicy,
      resources: effectivePolicy.resources())
    let artifactReferencer = try CoreSpiceCLIArtifactReferencer()
    if osdiCatalog != nil, options.caseOutput != nil,
       !loadedDeck.netlist.analyses.allSatisfy({ analysis in
         switch analysis { case .op, .ac, .transient, .noise, .sensitivity, .transferFunction: return true; default: return false }
       }) {
      throw CoreSpiceCLIOSDIError.unsupportedAnalysis("OSDI case qualification publication")
    }
    var inputArtifacts = loadedDeck.captures.map { capture in
      artifactReferencer.input(capture: capture, kind: .netlist, format: .spice)
    }
    if let osdiCatalog {
      for path in osdiCatalog.evidenceInputPaths.keys.sorted() {
        guard let reference = osdiCatalog.evidenceInputPaths[path] else { throw CLIError.state("Missing captured OSDI input identity") }
        if !inputArtifacts.contains(reference) { inputArtifacts.append(reference) }
      }
    }
    if let reference = effectivePolicy.executionProfileReference { inputArtifacts.append(reference) }
    let executableCapture = try options.caseOutput.map { _ in try CoreSpiceCLICasePublisher.captureExecutable() }
    let caseInputs = try options.caseOutput != nil ? osdiCatalog.map { try CoreSpiceCLICaseCapturedInput.capture($0, resources: effectivePolicy.resources()) } ?? [] : []
    for input in caseInputs where !inputArtifacts.contains(input.reference) { inputArtifacts.append(input.reference) }
    let precisionResources = try osdiCatalog?.executionBudget.map { _ in try effectivePolicy.resources() }
    let protectedPaths = loadedDeck.captures.compactMap(\.resolvedPath) + (osdiCatalog?.protectedInputPaths ?? [])
      + [options.executionProfilePath].compactMap { $0 }
    let fileOutputs = [options.pairedCSVPath, options.outputs.raw, options.outputs.csv, options.outputs.psf, options.outputs.coverageJSON, options.touchstonePath, options.networkDirectory].compactMap { $0 }
    if let caseOutput = options.caseOutput {
      try CoreSpiceCLICasePublisher.validateDestination(directory: caseOutput,
        protectedInputs: protectedPaths, otherOutputs: fileOutputs)
    }
    var publication = try CoreSpiceCLIPrecisionPublication(inputs: protectedPaths, outputs: fileOutputs)
    var publishedCaseDirectory: String?
    do {
    let stagedOutputs = OutputTargets(
      raw: try options.outputs.raw.map { try publication.stage(for: $0) },
      csv: try options.outputs.csv.map { try publication.stage(for: $0) },
      psf: try options.outputs.psf.map { try publication.stage(for: $0) })
    var outputArtifacts: [ArtifactReference] = []
    if let coveragePath = options.outputs.coverageJSON {
      let target = try publication.stage(for: coveragePath)
      try writeCoverageReport(loadedDeck.coverage, path: target)
      if let precisionResources, let budget = osdiCatalog?.executionBudget {
        try publication.chargeHash(path: target, maximumBytes: budget.maximumEvidenceBytes, resources: precisionResources)
      }
      outputArtifacts.append(try artifactReferencer.output(path: target, kind: .report, format: .json))
    }
    let precisionOutput: SPICENativeSimulationOutput?
    if let osdiCatalog, let budget = osdiCatalog.executionBudget {
      guard let resources = precisionResources else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing precision resource owner") }
      let capturedBytes = try loadedDeck.captures.reduce(UInt64(0)) { try CoreSpiceCLIPrecisionExecution.add($0, UInt64($1.bytes.count)) }
      let captureReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: capturedBytes)
      var sources: [SPICECheckedSource] = []
      let keyMap = Dictionary(uniqueKeysWithValues: loadedDeck.captures.enumerated().map { ($0.element.captureID, $0.offset == 0 ? "root" : $0.element.captureID) })
      for capture in loadedDeck.captures {
        let reference = artifactReferencer.input(capture: capture, kind: .netlist, format: .spice)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(capture.bytes.count))
        let array = Array(capture.bytes)
        sources.append(try .admit(binding: .init(key: keyMap[capture.captureID]!, reference: reference), bytes: array.span,
          resources: resources, maximumPageByteCount: 4096))
        withExtendedLifetime(scratch) {}
      }
      let routes = try loadedDeck.dependencyEvents.map { event in
        guard let parentID = event.parentCaptureID, let childID = event.childCaptureID,
              let parent = keyMap[parentID], let child = keyMap[childID] else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Captured dependency lacks exact parent/child") }
        return SPICESourceCatalogRoute(parentKey: parent, childKey: child, literalRoute: event.path,
          kind: event.kind, selectedSection: event.selectedSection)
      }
      let output = try await CoreSpicePreparedCommand.execute(sources: sources, routes: routes, policy: effectivePolicy,
        osdiCatalog: osdiCatalog, resources: resources)
      let completed = try CoreSpiceCLIPreparedRunRecord(output, budget: budget)
      try session.adoptPrecision(output: output, completed: completed, catalog: osdiCatalog)
      precisionOutput = output
      withExtendedLifetime(captureReservation) {}
    } else {
      precisionOutput = nil
      try session.loadNetlist(loadedDeck, randomSeed: options.randomSeed, osdiCatalog: osdiCatalog)
      session.accountedSourceDeck = loadedDeck
      session.networkOptions = options.network
      if let network = options.network {
        guard loadedDeck.netlist.analyses.indices.contains(network.analysisIndex),
              case .ac = loadedDeck.netlist.analyses[network.analysisIndex] else {
          throw CLIError.invalidArguments("Network --analysis-index must select exactly one source AC directive")
        }
      }
    }
    if options.caseOutput != nil { session.phaseCollector = try CoreSpiceCLIPhaseCollector() }
    reportOptionDiagnostics(session.analysisOptions.diagnostics)
    let analyses: [String]
    let waveformSummary: CoreSpiceCLIWaveformSummary?
    if precisionOutput != nil {
      guard let waveform = session.lastWaveform, let execution = session.completedOSDIExecution else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing adopted precision waveform") }
      guard let precision = execution.precision, let resources = precisionResources else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing precision publication owner") }
      if let pairedPath = options.pairedCSVPath {
        let target = try publication.stage(for: pairedPath)
        try execution.savePairedCSV(path: target)
        try publication.chargeHash(path: target, maximumBytes: precision.executionBudget.maximumEvidenceBytes, resources: resources)
        outputArtifacts.append(try artifactReferencer.output(path: target, kind: .waveform, format: .csv))
      }
      if let csvPath = options.outputs.csv {
        guard let target = stagedOutputs.csv else { throw CLIError.state("Missing CSV staging") }
        _ = try await SPICEIO.exportToCSV(waveform, path: target)
        try publication.chargeHash(path: target, maximumBytes: precision.executionBudget.maximumEvidenceBytes, resources: resources)
        outputArtifacts.append(try artifactReferencer.output(path: target, kind: .waveform, format: .csv))
      }
      analyses = ["tran"]
      waveformSummary = CoreSpiceCLIWaveformSummary(variables: waveform.variables.map(\.name), points: waveform.pointCount)
    } else if let mc = session.monteCarloSpec, session.parsedNetlist?.analyses.count == 1 {
      let parametric = try await session.runMonteCarlo(
        spec: mc,
        inner: mc.analysis,
        seedOverride: options.randomSeed
      )
      outputArtifacts += try await export(parametric: parametric, outputs: stagedOutputs)
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
      outputArtifacts += try await export(waveform: waveform, outputs: stagedOutputs)
      analyses = [override.analysisIdentifier]
      waveformSummary = CoreSpiceCLIWaveformSummary(
        variables: waveform.variables.map(\.name),
        points: waveform.pointCount
      )
    } else {
      let waveform = try await session.runDeclaredAnalyses()
      if let parametric = session.lastParametric {
        outputArtifacts += try await export(parametric: parametric, outputs: stagedOutputs)
      } else if options.network != nil {
        guard let run = session.completedNetworkCase else { throw CLIError.state("Missing selected network completion") }
        if let target = stagedOutputs.csv {
          try CoreSpiceCLINetworkExport.writeCSV([run], path: target, resources: effectivePolicy.resources(),
            maximumBytes: effectivePolicy.maximumTemporaryBytes, cancellation: .init())
          outputArtifacts.append(try artifactReferencer.output(path: target, kind: .waveform, format: .csv))
        }
        outputArtifacts += try await export(waveform: waveform, outputs: .init(raw: stagedOutputs.raw, psf: stagedOutputs.psf))
      } else { outputArtifacts += try await export(waveform: waveform, outputs: stagedOutputs) }
      analyses = session.analysisCompletions?.map(\.analysis) ?? session.parsedNetlist?.analyses.map(Session.analysisName) ?? []
      waveformSummary = CoreSpiceCLIWaveformSummary(
        variables: waveform.variables.map(\.name),
        points: waveform.pointCount, runs: session.lastParametric?.runs.count
      )
    }
    if let osdiCatalog, Set(session.completedOSDIModels.map(\.instanceName)).count != osdiCatalog.instances.count {
      throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed catalog instance receipts are missing")
    }
    if let directory = options.caseOutput, let caseID = options.caseID, let phases = session.phaseCollector {
      outputArtifacts += try CoreSpiceCLICasePublisher().publish(directory: directory, caseID: caseID,
        loadedDeck: loadedDeck, phases: phases, referencer: artifactReferencer, executableCapture: executableCapture, additionalInputs: caseInputs)
      publishedCaseDirectory = directory
    }
    if let touchstonePath = options.touchstonePath {
      guard let network = session.completedNetworkCase?.completion.network else { throw CLIError.state("Missing selected network result") }
      let target = try publication.stage(for: touchstonePath)
      try CoreSpiceCLINetworkExport.writeTouchstone(network, path: target, resources: effectivePolicy.resources(),
        maximumBytes: effectivePolicy.maximumTemporaryBytes, cancellation: .init())
      outputArtifacts.append(try artifactReferencer.output(path: target, kind: .waveform, format: ArtifactFormat(rawValue: "touchstone")))
    }
    if let directory = options.networkDirectory {
      guard let run = session.completedNetworkCase else { throw CLIError.state("Missing network member") }
      let resources = try effectivePolicy.resources()
      let family = try CoreSpiceCLIPreparedRunRecord(cases: [run], expectedCaseCount: 1, temperatureCount: 1,
        numericalUsage: CoreSpiceCLINumericalUsage(run.statistics), resources: resources)
      let target = try publication.stageDirectory(for: directory)
      try CoreSpiceCLINetworkExport.writeFamily(family, serializedJSON: nil, directory: target,
        resources: resources, maximumBytes: effectivePolicy.maximumTemporaryBytes, cancellation: .init())
    }
    for reference in session.analysisCompletions?.compactMap(\.preparedCompletionArtifact) ?? [] {
      if !outputArtifacts.contains(reference) { outputArtifacts.append(reference) }
    }
    let summary = CoreSpiceCLIBatchRunRecord(
      producer: artifactReferencer.producer,
      solverIdentity: SparseLUSolver.implementationIdentity,
      executionProfile: effectivePolicy.executionProfile,
      executionProfileReference: effectivePolicy.executionProfileReference,
      resolutionProfile: session.policy.profile.rawValue,
      diodeResolutionProfile: CoreSpiceCLIDiodeRecord.identifier(session.policy.diodeProfile),
      diodeModels: session.completedDiodeModels,
      osdiModels: session.analysisCompletions == nil && !session.completedOSDIModels.isEmpty ? session.completedOSDIModels : nil,
      osdiVariables: session.analysisCompletions == nil ? session.completedOSDIVariables : nil,
      osdiExecution: session.analysisCompletions == nil ? session.completedOSDIExecution : nil,
      nativeDCResult: session.analysisCompletions == nil && session.lastParametric == nil ? session.completedNativeDCResult : nil,
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
      analysisCompletions: session.analysisCompletions,
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
    let hasSourceCompletion = summary.analysisCompletions?.contains { $0.preparedCompletionJSON != nil } == true
    let serializationResources = try hasSourceCompletion ? effectivePolicy.resources() : precisionResources
    let upper = try hasSourceCompletion ? CoreSpiceCLIJSONUpperBound.count(summary,
      maximumBytes: effectivePolicy.maximumTemporaryBytes / 4, resources: effectivePolicy.resources()) : nil
    let scratch = try upper.map { try effectivePolicy.resources().reserveStorage(kind: .temporaryBytes,
      byteCount: CoreSpiceCLIPrecisionExecution.multiply($0, 4)) }
    let serialized = summary.osdiExecution?.precision == nil && !hasSourceCompletion ? nil : try CoreSpiceCLIJSON.encode(summary)
    var serializationReservation: SPICESourceStorageReservation?
    if let serialized, let serializationResources {
      guard upper.map({ UInt64(serialized.utf8.count) <= $0 }) ?? true else { throw CoreSpiceCLICaseError.incompleteOutput("Batch source completion exceeds admitted serialization") }
      let decoder = options.network == nil ? JSONDecoder() : try session.networkDecoder()
      _ = try decoder.decode(CoreSpiceCLIBatchRunRecord.self, from: Data(serialized.utf8))
      serializationReservation = try serializationResources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(serialized.utf8.count))
    }
    withExtendedLifetime(scratch) { }
    try Task.checkCancellation()
    try publication.publish()
    return (summary, serialized, serializationReservation)
    } catch {
      var primary = error
      if let publishedCaseDirectory {
        do { try FileManager.default.removeItem(atPath: publishedCaseDirectory) }
        catch let cleanup { primary = CoreSpiceCLICaseError.incompleteOutput("Batch output failed: \(error); case cleanup failed: \(cleanup)") }
      }
      try publication.failed(primary)
      throw error
    }
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
    var publication = try CoreSpiceCLIPrecisionPublication(inputs: session.protectedInputPaths, outputs: [path])
    do {
      let target = try publication.stage(for: path)
      try await export(waveform: waveform, outputs: format.outputTargets(path: target))
      try publication.publish()
    } catch { try publication.failed(error) }
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
        corespice prepared <root.cir> [--execution-profile profile.json] [--json] [--osdi-catalog catalog.json] [--csv out.csv] [--paired-csv exact.csv] [--mos-profile profile] [--diode-profile profile] [--seed seed] [--source key path] [--include parent route child] [--library parent route child section]
        corespice --action-domain [--json]
        corespice metric-improvement-objective --measurement-report report.json --specification spec.json --parameter-space bounds.json [--output problem.json] [--problem-id id] [--created-at timestamp] [--pretty]
        corespice convergence-recovery-objective --diagnostic-report diagnostics.json --netlist deck.cir --analysis-options options.json [--retry-policy policy.json] [--output problem.json] [--problem-id id] [--created-at timestamp] [--pretty]
        corespice -b <deck.cir> [--execution-profile profile.json] [--json] [--osdi-catalog catalog.json] [--mos-profile profile] [--diode-profile profile] [--seed seed] [--tran tstep tstop | --ac dec|lin points start stop | --dc source start stop step] [-r out.raw] [--csv out.csv] [--paired-csv exact.csv] [--psf out.psf] [--coverage-json report.json] [--case-output new-directory --case-id id]
        corespice measure --waveform <path.csv> --measure "<spec>" [--measure "<spec>" ...] [--json]
        corespice            # interactive shell

      Transient resource policy:
        A complete source .options policy overrides the selected finite developer policy:
        tranmaxaccepted, tranmaxattempts, tranmaxiterations, tranmaxscalars,
        tranmaxdimension, tranmaxwork, tranmaxbreakpoints. Values are positive
        integers; saved scalars include times and all MNA variables. Work units
        are size-weighted operation counts, not wall time or measured FLOPS.

      OSDI native analysis:
        --osdi-catalog selects schema1 ordinary bindings, schema2 explicit precision/budgets, or schema3 explicit simulation parameters with required baseCatalogSchemaVersion 1/2.
        Precision output paths must be fresh; existing files and input/output aliases are refused.
        --paired-csv saves canonical high/low transient components with exact bit patterns; requires catalog schema2 or schema3 base 2.
        N instances use coefficient-free .model name osdi; catalog keys are exact normalized names.
        Ordinary OSDI supports .op, .ac, .tran, .noise, .tf and source DC/AC .sens.
        Prepared OSDI additionally supports .dc, .pz and .four; other analyses fail explicitly.
        Catalog reads are bounded to 4 MiB; artifacts are digest-checked.
        Completed JSON retains actual descriptor/scoped parameters/Kelvin, raw/global rows,
        full real/complex samples, actual OP, accepted transient steps and noise source PSDs.

      Source evaluation policy:
        --mos-profile coreStrictV1|pinnedNgspiceNormalV1 selects explicit MOS input semantics.
        --diode-profile coreDiodeV1|genericDiodeV1 selects checked diode semantics (default genericDiodeV1).
        Diode preparation admits 64 KiB retained, 4 KiB temporary and 1024 logical work per owner.
        Nonzero Rs/sidewall and unsupported law/version selectors fail explicitly.
        The named developerV1 policy selects pinnedNgspiceNormalV1 and seed 1 unless overridden
        by --mos-profile or --seed. Monte Carlo uses a new scalar session per seed.
        Source .mc admits tran, ac and dc inner analyses.
        Resolution admits 8192 elements, depth 64, 16 MiB retained source evaluation,
        1 MiB diagnostics and 1e9 evaluation steps. Native preparation admits 256 MNA
        dimensions and 64 MiB, with 1 MiB retained/temporary storage per MOS owner.
        Invocation resources admit 128 MiB live, 64 MiB temporary and 1e9 logical work.
        --analysis-index N --network-port source reference-ohms [--network-port ...]
        --network-residual-tolerance value selects that source AC as fixed-bias network extraction.
        Network frequencies and reference resistances must be finite and positive; tolerance is between 0 and 1.
        --touchstone out.sNp exports one case; --network-output-directory new-directory saves every case.
        Network --csv uses explicit S/Y/Z availability rows; JSON retains OP, model and port identities.
        --execution-profile reads a closed JSON object bounded to 64 KiB with required
        schemaVersion=1, maximumElements, maximumNativeAllocationBytes,
        maximumLiveOwnedBytes, maximumTemporaryBytes, maximumHashedBytes,
        maximumSourceBytes, maximumPreparationWorkUnits, maximumResolutionRetainedBytes.
        All ceilings are positive representable integers selected by the caller.
        The complete profile and exact input identity are saved in completion JSON.
        It conflicts with OSDI executionBudget; source numerical .options stay authoritative.
        Exceeding these selected ceilings fails; they do not guarantee wall time or qualification.

      Canonical case output:
        --case-output publishes exact captured inputs, executable, model receipts,
        execution.json and availability.json in a new directory. Completed phase
        observations retain actual DC points and Monte Carlo seeds. This emits
        original evidence; it does not issue qualification. Sensitivity retains actual
        baseline/child physical observations, fresh source patches and a derived
        sensitivity artifact; undefined normalized values remain unavailable.

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
  fileprivate var accountedSourceDeck: LoadedSPICEDeck?
  var phaseCollector: CoreSpiceCLIPhaseCollector?
  private(set) var plan: ExecutionPlan?
  private(set) var resolved: CoreSpiceCLIResolvedCircuit?
  private(set) var lastWaveform: WaveformData?
  private(set) var lastParametric: ParametricWaveformData?
  private(set) var lastMeasurements: [SPICEMeasurementResult] = []
  private(set) var lastSource = ""
  private(set) var protectedInputPaths: [String] = []
  private var completedSourceCompletion: CoreSpiceCLISourceCompletion?
  private(set) var analysisCompletions: [CoreSpiceCLIAnalysisCompletion]?
  private(set) var completedDiodeModels: [CoreSpiceCLIDiodeRecord] = []
  private var osdiCatalog: CoreSpiceCLIOSDICatalog.Loaded?
  private(set) var completedOSDIModels: [CoreSpiceCLIOSDIRecord] = []
  private(set) var completedOSDIVariables: [CoreSpiceCLIOSDIVariableRecord]?
  private(set) var completedNativeDCResult: SPICENativeStoredDCResult?
  private(set) var completedOSDIExecution: CoreSpiceCLIOSDIExecutionRecord?
  private var precisionNetlist: ParsedNetlist?
  private var precisionOptions: SPICEAnalysisOptions?
  private var precisionPrepared: (input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits, runtime: SPICEOSDIRuntimeInputs)?
  func networkDecoder(cancellation: CancellationToken = .init()) throws -> JSONDecoder {
    guard let numericalExecutionResources else { throw CLIError.state("Missing RF verification invocation") }
    return CoreSpiceCLIJSON.networkDecoder(numericalResources: numericalExecutionResources,
      sourceResources: try policy.resources(), cancellation: cancellation)
  }
  var networkOptions: CoreSpiceCLINetworkOptions?
  private(set) var completedNetworkCase: CoreSpiceCLIPreparedCase?
  private var sourcePreparedInput: PreparedSPICESimulation?
  private var compiled: CompiledNetlist?
  private var loadedSeed: UInt64
  private var loadedSeedOverride: UInt64?
  private var numericalExecutionResources: AnalysisExecutionResources?
  var parsedNetlist: ParsedNetlist? { precisionNetlist ?? compiled?.source }
  var analysisOptions: SPICEAnalysisOptions { precisionOptions ?? resolved?.options ?? sourcePreparedInput?.configuration.options ?? .default }
  var monteCarloSpec: MonteCarloSpec? {
    parsedNetlist?.analyses.compactMap { if case .monteCarlo(let spec) = $0 { return spec }; return nil }.first
  }
  var isLoaded: Bool { compiled != nil || precisionPrepared != nil }

  init(policy: CoreSpiceCLIExecutionPolicy) { self.policy = policy; loadedSeed = policy.seed }

  mutating func loadNetlist(source: String, fileName: String?) async throws {
    try loadNetlist(try await SPICEDeckLoader.load(source: source, fileName: fileName))
  }

  mutating func loadNetlist(_ deck: LoadedSPICEDeck, randomSeed: UInt64? = nil,
                            osdiCatalog: CoreSpiceCLIOSDICatalog.Loaded? = nil) throws {
    if policy.executionProfile != nil {
      var count = 1
      for extent in [deck.netlist.components.count, deck.netlist.models.count, deck.netlist.controls.count,
                     deck.netlist.parameters.count, deck.netlist.initialConditions.count,
                     deck.netlist.nodeSets.count, deck.netlist.analyses.count, deck.netlist.dependencyEvents.count] {
        let (next, overflow) = count.addingReportingOverflow(extent)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }; count = next
      }
      guard count <= policy.maximumElements else {
        throw SPICESimulationCapacityError.elements(boundary: .parsedTransform, limit: policy.maximumElements, requested: count)
      }
    }
    let control = CoreSpiceCLIResolutionControl(resources: try policy.resources(), cancellation: nil)
    let candidate: CompiledNetlist
    do { candidate = try NetlistLowering.compile(deck.netlist, limits: policy.resolutionLimits, control: control) }
    catch { throw control.preservingResourceCause(error) }
    let seed = randomSeed ?? policy.seed
    let values = try CoreSpiceCLIResolvedCircuit.resolve(candidate, policy: policy,
      seed: seed, selectedAnalysisIndex: nil, osdiInstances: osdiCatalog?.instances ?? [:])
    // Publish only a complete immutable source evaluation; failed replacement keeps the prior deck.
    self.osdiCatalog = osdiCatalog
    protectedInputPaths = deck.captures.compactMap(\.resolvedPath) + (osdiCatalog?.protectedInputPaths ?? [])
    accountedSourceDeck = deck
    precisionNetlist = nil; precisionOptions = nil; precisionPrepared = nil
    compiled = candidate; resolved = values; sourcePreparedInput = nil; loadedSeed = seed; loadedSeedOverride = randomSeed; lastSource = deck.source
    plan = nil; phaseCollector = nil; lastWaveform = nil; lastParametric = nil
    lastMeasurements = []; completedDiodeModels = []; completedOSDIModels = []; completedOSDIVariables = nil; completedOSDIExecution = nil; completedNativeDCResult = nil
  }

  mutating func adoptPrecision(output: SPICENativeSimulationOutput, completed: CoreSpiceCLIPreparedRunRecord,
                               catalog: CoreSpiceCLIOSDICatalog.Loaded) throws {
    guard let execution = completed.osdiExecution, execution.precision != nil else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing actual precision completion") }
    var candidate = self
    candidate.precisionNetlist = output.prepared.input.netlist; candidate.precisionOptions = output.prepared.input.configuration.options
    guard let runtime = output.prepared.osdiRuntimeInputs else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing retained precision runtime") }
    candidate.precisionPrepared = (output.prepared.input, output.prepared.limits, runtime)
    candidate.compiled = nil; candidate.resolved = nil; candidate.osdiCatalog = catalog; candidate.plan = output.prepared.plan
    candidate.phaseCollector = nil; candidate.lastParametric = nil
    candidate.completedNativeDCResult = nil
    candidate.completedOSDIModels = completed.osdiModels ?? []; candidate.completedOSDIExecution = execution; candidate.completedOSDIVariables = nil
    candidate.completedDiodeModels = completed.diodeModels
    candidate.lastMeasurements = try candidate.evaluateMeasurements(for: output.waveform)
    candidate.lastWaveform = try SPICEOutputProjector.project(output.waveform, controls: output.prepared.input.netlist.controls)
    self = candidate
  }

  private mutating func runRetainedPrecision(_ analysis: ParsedAnalysisCommand, cancellation: CancellationToken) async throws -> WaveformData {
    guard let prepared = precisionPrepared, let catalog = osdiCatalog,
          let budget = catalog.executionBudget,
          prepared.input.netlist.analyses.indices.contains(prepared.input.configuration.analysisIndex),
          prepared.input.netlist.analyses[prepared.input.configuration.analysisIndex] == analysis else {
      throw CoreSpiceCLIOSDIError.unsupportedAnalysis("Retained precision execution requires the original source-selected transient")
    }
    let native = SPICENativeSimulation()
    let owner = try await native.prepare(prepared.input, limits: prepared.limits, osdi: prepared.runtime)
    let output = try await native.execute(owner, cancellation: cancellation)
    let completed = try CoreSpiceCLIPreparedRunRecord(output, budget: budget)
    // Build the replacement while the last complete observation remains owned.
    var candidate = self
    try candidate.adoptPrecision(output: output, completed: completed, catalog: catalog)
    guard let waveform = candidate.lastWaveform else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing retained precision waveform") }
    self = candidate
    return waveform
  }

  mutating func run(_ command: AnalysisCommand, cancellation: CancellationToken = CancellationToken()) async throws -> WaveformData {
    if precisionPrepared != nil {
      guard case .tran(let step, let stop) = command else { throw CoreSpiceCLIOSDIError.unsupportedAnalysis("Precision overrides require the original transient") }
      return try await runRetainedPrecision(.transient(.init(stopTime: .numeric(stop), stepTime: .numeric(step))), cancellation: cancellation)
    }
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
      seed: loadedSeed, selectedAnalysisIndex: nil, cancellation: cancellation, osdiInstances: osdiCatalog?.instances ?? [:])
    resolved = values
    let waveform = try await execute(analysis, values: values, phasePrefix: "", cancellation: cancellation)
    return try finish(waveform, controls: compiled.source.controls)
  }

  private mutating func runExplicitAC(_ sweep: FrequencySweep, cancellation: CancellationToken) async throws -> WaveformData {
    guard let compiled else { throw CLIError.state("no netlist loaded") }
    try beginRun()
    let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
      seed: loadedSeed, selectedAnalysisIndex: nil, cancellation: cancellation, osdiInstances: osdiCatalog?.instances ?? [:])
    resolved = values
    let owner = try await prepare(values, capabilities: [.dc, .ac])
    let record = owner.record
    let run = try await ACAnalysis(sweep: sweep, dcConfig: values.options.convergence, nodeInitialGuess: values.nodeSetVoltages).run(
      circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: cancellation)
    let waveform = try WaveformData.from(acResult: run.result, variableLayout: variableLayout(record, map: run.result.variableMap), title: "AC")
    try retain(run.phases, record: record, waveform: waveform, prefix: "", operatingPoint: run.result.operatingPoint)
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

  private static func requiresCapturedSourceExecution(_ analysis: ParsedAnalysisCommand) -> Bool {
    switch analysis { case .sensitivity, .transferFunction: return true; default: return false }
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

  mutating func runParsed(_ analysis: ParsedAnalysisCommand, cancellation: CancellationToken = .init()) async throws -> WaveformData {
    if precisionPrepared != nil { return try await runRetainedPrecision(analysis, cancellation: cancellation) }
    if Self.requiresCapturedSourceExecution(analysis) || networkOptions?.analysisIndex == parsedNetlist?.analyses.firstIndex(of: analysis) {
      guard let deck = accountedSourceDeck, let index = deck.netlist.analyses.firstIndex(of: analysis) else {
        throw CLIError.state("analysis is outside the loaded source")
      }
      try beginRun()
      let waveform = try await runSourceAnalysis(at: index, phasePrefix: "", cancellation: cancellation)
      let projected = try finish(waveform, controls: deck.netlist.controls)
      if let source = completedSourceCompletion {
        analysisCompletions = [try .init(analysis: waveform.metadata.analysisType == .networkParameters ? "network" : Self.analysisName(analysis),
          waveform: .init(variables: projected.variables.map(\.name), points: projected.pointCount),
          nativeDCResult: nil, osdiExecution: nil, osdiModels: nil, osdiVariables: nil,
          preparedCompletionJSON: source.json, preparedCompletionArtifact: source.artifact, sourceCompletion: source)]
      }
      return projected
    }
    guard let compiled, let index = compiled.source.analyses.firstIndex(of: analysis) else {
      throw CLIError.state("analysis is outside the loaded source")
    }
    try beginRun()
    let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
      seed: loadedSeed, selectedAnalysisIndex: index, cancellation: cancellation, osdiInstances: osdiCatalog?.instances ?? [:])
    resolved = values
    let waveform = try await execute(values.analyses[index], values: values,
      phasePrefix: "", cancellation: cancellation, analysisIndex: index)
    return try finish(waveform, controls: compiled.source.controls)
  }

  /// One invocation owns all declared numerical phases and their observations.
  mutating func runDeclaredAnalyses(cancellation: CancellationToken = .init()) async throws -> WaveformData {
    guard let netlist = parsedNetlist else { throw CLIError.state("no netlist loaded") }
    let analyses = netlist.analyses
    guard !analyses.isEmpty else { throw CLIError.missingAnalysisDirective }
    _ = try defaultRunnableAnalysis()
    if analyses.count == 1 { return try await runParsed(analyses[0], cancellation: cancellation) }
    try beginRun()
    var measurements: [SPICEMeasurementResult] = []
    var completions: [CoreSpiceCLIAnalysisCompletion] = []
    for (index, analysis) in analyses.enumerated() {
      try Task.checkCancellation()
      if cancellation.isCancelled { throw CancellationError() }
      if case .monteCarlo(let spec) = analysis {
        let result = try await runMonteCarlo(spec: spec, inner: spec.analysis, seedOverride: loadedSeedOverride,
          cancellation: cancellation, retainingPriorPhases: true, phasePrefix: "analysis:\(index):")
        measurements += lastMeasurements
        guard let waveform = result.runs.first?.waveform else { throw CLIError.state("Empty Monte Carlo completion") }
        completions.append(try .init(analysis: "mc(\(Self.analysisName(spec.analysis)))",
          waveform: .init(variables: waveform.variables.map(\.name), points: waveform.pointCount, runs: result.runs.count),
          nativeDCResult: nil, osdiExecution: nil, osdiModels: nil, osdiVariables: nil))
        continue
      }
      lastParametric = nil
      guard Self.isRunnableAnalysis(analysis) else { throw CLIError.unsupportedAnalysis(Self.analysisName(analysis)) }
      let prefix = "analysis:\(index):"
      let modelStart = completedOSDIModels.count
      completedSourceCompletion = nil; completedNativeDCResult = nil; completedOSDIExecution = nil; completedOSDIVariables = nil
      let waveform: WaveformData
      if Self.requiresCapturedSourceExecution(analysis) || networkOptions?.analysisIndex == index {
        waveform = try await runSourceAnalysis(at: index, phasePrefix: prefix, cancellation: cancellation)
      } else {
        guard let compiled else { throw CLIError.state("missing compiled source evidence") }
        let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
          seed: loadedSeed, selectedAnalysisIndex: index, cancellation: cancellation, osdiInstances: osdiCatalog?.instances ?? [:])
        resolved = values
        waveform = try await execute(values.analyses[index], values: values, phasePrefix: prefix, cancellation: cancellation, analysisIndex: index)
      }
      let observed = try evaluateMeasurements(for: waveform)
      measurements += observed
      try phaseCollector?.measurements(observed, prefix: prefix,
        phaseIDs: phaseCollector?.phases.filter { $0.id.hasPrefix(prefix) }.map(\.id) ?? [])
      let projected = try SPICEOutputProjector.project(waveform, controls: netlist.controls)
      lastWaveform = projected
      try completedOSDIExecution?.project(projected)
      let models = Array(completedOSDIModels.dropFirst(modelStart))
      completions.append(try .init(analysis: waveform.metadata.analysisType == .networkParameters ? "network" : Self.analysisName(analysis),
        waveform: .init(variables: projected.variables.map(\.name), points: projected.pointCount),
        nativeDCResult: completedSourceCompletion == nil ? completedNativeDCResult : nil,
        osdiExecution: completedSourceCompletion == nil ? completedOSDIExecution : nil,
        osdiModels: completedSourceCompletion == nil && !models.isEmpty ? models : nil,
        osdiVariables: completedSourceCompletion == nil ? completedOSDIVariables : nil,
        preparedCompletionJSON: completedSourceCompletion?.json, preparedCompletionArtifact: completedSourceCompletion?.artifact, sourceCompletion: completedSourceCompletion))
    }
    try requireAllMeasurements(measurements)
    analysisCompletions = completions
    lastMeasurements = measurements
    phaseCollector?.finish()
    guard let lastWaveform else { throw CLIError.missingAnalysisDirective }
    return lastWaveform
  }

  mutating func runMonteCarlo(spec: MonteCarloSpec, inner: ParsedAnalysisCommand,
                             seedOverride: UInt64? = nil, cancellation: CancellationToken = .init(),
                             retainingPriorPhases: Bool = false, phasePrefix: String = "") async throws -> ParametricWaveformData {
    guard let compiled, let index = compiled.source.analyses.firstIndex(where: {
      if case .monteCarlo(let candidate) = $0 { return candidate == spec }; return false
    }), inner == spec.analysis else { throw CLIError.state("Monte Carlo is outside the loaded source") }
    guard osdiCatalog == nil else { throw CoreSpiceCLIOSDIError.unsupportedAnalysis("monteCarlo") }
    guard spec.iterations > 0, spec.iterations <= policy.maximumElements else {
      throw CLIError.invalidArguments("Monte Carlo iteration budget exceeded")
    }
    if phaseCollector != nil, spec.iterations > 10_000 {
      throw CoreSpiceCLICaseError.incompleteOutput("Monte Carlo phase budget exceeded")
    }
    if !retainingPriorPhases { try beginRun() }
    var runs: [ParametricWaveformData.Run] = []
    var firstMeasurements: [SPICEMeasurementResult] = []
    let seed = seedOverride ?? spec.seed.map(UInt64.init) ?? loadedSeed
    for iteration in 0..<spec.iterations {
      try Task.checkCancellation()
      if cancellation.isCancelled { throw CancellationError() }
      let (runSeed, overflow) = seed.addingReportingOverflow(UInt64(iteration))
      guard !overflow else { throw CLIError.invalidArguments("Monte Carlo seed overflow") }
      let values = try CoreSpiceCLIResolvedCircuit.resolve(compiled, policy: policy,
        seed: runSeed, selectedAnalysisIndex: index, cancellation: cancellation, osdiInstances: osdiCatalog?.instances ?? [:])
      guard case .monteCarlo(let selected) = values.analyses[index] else {
        throw CLIError.state("resolved Monte Carlo shape changed")
      }
      resolved = values
      let prefix = phasePrefix + "mc-seed:\(runSeed):"
      let waveform = try await execute(selected.analysis, values: values,
        phasePrefix: prefix, cancellation: cancellation)
      let measurements = try evaluateMeasurements(for: waveform)
      if !retainingPriorPhases { try requireAllMeasurements(measurements) }
      try phaseCollector?.measurements(measurements, prefix: prefix,
        phaseIDs: phaseCollector?.phases.filter { $0.id.hasPrefix(prefix) }.map(\.id) ?? [])
      if iteration == 0 { firstMeasurements = measurements }
      let runReservation = try values.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 256)
      let projected = try SPICEOutputProjector.project(waveform, controls: compiled.source.controls)
      runs.append(try .init(validatingIndex: iteration, parameters: ["run": Double(iteration)],
        waveform: projected.retainingStorage(CoreSpiceCLIEnsembleStorage(native: projected.retainedStorage, run: runReservation))))
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
    analysisCompletions = nil; numericalExecutionResources = nil; completedSourceCompletion = nil; completedNetworkCase = nil
    plan = nil; lastWaveform = nil; lastParametric = nil; lastMeasurements = []; completedDiodeModels = []; completedOSDIModels = []; completedOSDIVariables = nil; completedOSDIExecution = nil; completedNativeDCResult = nil
  }

  private mutating func finish(_ waveform: WaveformData, controls: [ParsedControlStatement]) throws -> WaveformData {
    if let osdiCatalog, Set(completedOSDIModels.map(\.instanceName)).count != osdiCatalog.instances.count {
      throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed catalog instance receipts are missing")
    }
    let measurements = try evaluateMeasurements(for: waveform)
    try requireAllMeasurements(measurements)
    let projected = try SPICEOutputProjector.project(waveform, controls: controls)
    try completedOSDIExecution?.project(projected)
    if let completedOSDIExecution { try completedOSDIExecution.validate(models: completedOSDIModels) }
    try phaseCollector?.measurements(measurements, prefix: "", phaseIDs: phaseCollector?.phases.map(\.id) ?? [])
    phaseCollector?.finish(); lastWaveform = projected; lastParametric = nil; lastMeasurements = measurements
    return projected
  }

  private mutating func prepare(_ values: CoreSpiceCLIResolvedCircuit, capabilities: MOSAnalysisCapabilities) async throws -> PreparedNativeCircuit {
    let options = values.options
    guard !options.executionLimitOptionsPresent || options.executionLimits != nil else {
      throw CLIError.invalidArguments("execution policy is incomplete")
    }
    let conditions = try options.operatingConditions()
    let requestedCapabilities = capabilities
    var registry = options.deviceRegistry(); registry.registerOptoelectronicDevices()
    let numericalLimits = options.executionLimits ?? policy.numericalLimits
    let limits = SPICENativeExecutionLimits(maximumDeviceCount: policy.maximumElements,
      maximumMatrixDimension: numericalLimits.maximumMatrixDimension, maximumAllocationBytes: policy.maximumAllocationBytes,
      mosPreparationLimits: policy.preparationLimits,
      mosPreparationConditions: try .init(ambientKelvin: conditions.temperatureKelvin,
        nominalKelvin: conditions.nominalTemperatureKelvin, analysisCapabilities: requestedCapabilities), diodePreparationLimits: policy.diodePreparationLimits,
      diodeAnalyses: .init(rawValue: requestedCapabilities.rawValue))
    if numericalExecutionResources == nil { numericalExecutionResources = try .init(limits: numericalLimits) }
    guard let numericalExecutionResources else { throw CLIError.state("Missing numerical invocation owner") }
    let owner: PreparedNativeCircuit
    if let osdiCatalog {
      owner = try await NativeCircuitPreparer().prepare(ir: values.lowered.circuit, registry: registry,
        operatingConditions: conditions, limits: limits, numericalLimits: numericalLimits,
        resources: values.resources, osdi: osdiCatalog.runtime)
    } else {
      owner = try NativeCircuitPreparer().prepare(ir: values.lowered.circuit, registry: registry,
        operatingConditions: conditions, limits: limits, numericalLimits: numericalLimits, resources: values.resources)
    }
    return try owner.usingExecutionResources(numericalExecutionResources)
  }

  private func variableLayout(_ record: NativeCircuitPreparationRecord, map: [MNAVariable: Int]) throws -> WaveformVariableLayout {
    let thermal = Set(record.osdiVariableKinds.compactMap { variable, kind -> Node? in
      if kind == .thermalPotential, case .nodeVoltage(let node) = variable { return node }; return nil
    })
    return try .init(validatingVariableMap: map, topology: record.plan.topology.circuitTopology, temperatureRiseNodes: thermal)
  }

  private mutating func retain(_ phases: [NativeCircuitExecutionFacts], record: NativeCircuitPreparationRecord,
                               waveform: WaveformData, prefix: String, collectPhases: Bool = true,
                               poleZeroResult: PoleZeroResult? = nil, operatingPoint: DCResult? = nil,
                               transient: TransientResult? = nil, noise: NoiseResult? = nil,
                               compiledOverride: CompiledNetlist? = nil) throws {
    let compiled = try compiledOverride ?? recordCompiled()
    plan = record.plan
    if [.sensitivity, .transferFunction, .networkParameters].contains(waveform.metadata.analysisType) {
      completedOSDIExecution = nil; completedOSDIVariables = nil
    } else if !record.osdiPreparationRecords.isEmpty, waveform.metadata.analysisType != .operatingPoint {
      completedOSDIExecution = try .init(record: record, waveform: waveform, operatingPoint: operatingPoint, transient: transient, noise: noise)
      completedOSDIVariables = nil
    } else {
      completedOSDIVariables = try CoreSpiceCLIOSDIVariableRecord.records(record, waveform: waveform)
    }
    for (index, facts) in phases.enumerated() {
      let phaseID: String
      if let source = facts.sourceName, let value = facts.sourceValue {
        phaseID = "\(prefix)dc:\(source):point:\(index):value:\(value)"
      } else { phaseID = prefix + facts.analysis }
      if collectPhases, let phaseCollector {
        let observed: WaveformData
        if facts.analysis == "op", let operatingPoint {
          observed = try .from(dcResult: operatingPoint,
            variableLayout: variableLayout(record, map: operatingPoint.variableMap), title: "Operating Point")
        } else { observed = waveform }
        try phaseCollector.record(id: phaseID, facts: facts,
          compiled: compiled, waveform: observed, poleZeroResult: facts.analysis == "op" ? nil : poleZeroResult)
      }
      guard facts.osdiPreparationRecords.count == record.osdiPreparationRecords.count else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed OSDI facts are missing")
      }
      for completed in facts.osdiPreparationRecords {
        completedOSDIModels.append(try .init(phase: facts.analysis, completed: completed,
          completedPointCount: facts.completedPointCount,
          sourceName: facts.analysis == "dc" ? facts.sourceName : nil,
          sourceValue: facts.analysis == "dc" ? facts.sourceValue : nil,
          sourcePointIndex: facts.analysis == "dc" ? index : nil))
      }
      for child in facts.sourceReexecutions {
        for receipt in child.preparation.diodePreparationReceipts {
          guard let model = child.selectedDiodeModels[receipt.identity.resolved.instance] else {
            throw CLIError.state("Missing actual fresh diode model name")
          }
          completedDiodeModels.append(.init(phase: phaseID + ":child:" + child.deviceName + "." + child.parameterName,
            receipt: receipt, modelName: model, completedPointCount: child.completedPhase.completedPointCount))
        }
      }
      for (perturbation, receipt) in (facts.sourceReexecutions.isEmpty ? facts.diodePerturbationReceipts : []).enumerated() {
        let model = try compiled.modelName(for: receipt.identity.resolved)
        completedDiodeModels.append(.init(phase: phaseID + ":diode-perturbation:" + String(perturbation),
          receipt: receipt, modelName: model, completedPointCount: facts.completedPointCount))
      }
      for receipt in record.diodePreparationReceipts {
        let model = try compiled.modelName(for: receipt.identity.resolved)
        completedDiodeModels.append(.init(phase: phaseID, receipt: receipt, modelName: model,
          completedPointCount: facts.completedPointCount))
      }
    }
  }

  private func recordCompiled() throws -> CompiledNetlist {
    guard let compiled else { throw CLIError.state("missing compiled source evidence") }; return compiled
  }

  private mutating func execute(_ analysis: ParsedAnalysisCommand, values: CoreSpiceCLIResolvedCircuit,
                                phasePrefix: String, cancellation: CancellationToken,
                                analysisIndex: Int? = nil) async throws -> WaveformData {
    if case .sensitivity = analysis {
      guard let analysisIndex else { throw CLIError.state("Sensitivity source analysis identity is missing") }
      return try await runSourceAnalysis(at: analysisIndex,
        phasePrefix: phasePrefix, cancellation: cancellation)
    }
    if values.lowered.circuit.instances.contains(where: { $0.osdi != nil }) {
      switch analysis {
      case .op, .ac, .transient, .noise: break
      default: throw CoreSpiceCLIOSDIError.unsupportedAnalysis(Self.analysisName(analysis))
      }
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
    let owner = try await prepare(values, capabilities: capabilities)
    let record = owner.record
    let plan = record.plan
    let solver = SparseLUSolver()
    let waveform: WaveformData
    var poleZeroResult: PoleZeroResult?
    var operatingPoint: DCResult?
    var dcSweepResult: SweepResult<DCResult>?
    var transient: TransientResult?
    var noise: NoiseResult?
    let phases: [NativeCircuitExecutionFacts]
    switch analysis {
    case .op:
      let run = try await DCAnalysis(config: options.convergence, nodeInitialGuess: values.nodeSetVoltages)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      operatingPoint = run.result
      if record.osdiPreparationRecords.isEmpty {
        waveform = .from(dcResult: run.result, topology: plan.topology.circuitTopology, title: "Operating Point")
      } else {
        var thermalNodes: Set<Node> = []
        for (variable, kind) in record.osdiVariableKinds {
          if kind == .thermalPotential, case .nodeVoltage(let node) = variable { thermalNodes.insert(node) }
        }
        let layout = try WaveformVariableLayout(validatingVariableMap: run.result.variableMap,
          topology: plan.topology.circuitTopology, temperatureRiseNodes: thermalNodes)
        waveform = try .from(dcResult: run.result, variableLayout: layout, title: "Operating Point")
      }
      phases = run.phases
    case .transient(let spec):
      let config = try Self.makeTransientConfig(spec: spec, values: values, limits: policy.numericalLimits)
      let run = try await TransientAnalysis(config: config, convergenceConfig: options.convergence)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = try .checkedFrom(transientResult: run.result, variableLayout: variableLayout(record, map: run.result.variableMap), title: "Transient"); phases = run.phases
      operatingPoint = run.result.operatingPoint; transient = run.result
    case .ac(let spec):
      let run = try await ACAnalysis(sweep: Self.frequencySweep(from: spec), dcConfig: options.convergence, nodeInitialGuess: values.nodeSetVoltages)
        .run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: cancellation)
      waveform = try .from(acResult: run.result, variableLayout: variableLayout(record, map: run.result.variableMap), title: "AC"); phases = run.phases
      operatingPoint = run.result.operatingPoint
    case .dc(let spec):
      guard spec.source2 == nil else { throw CLIError.unsupportedAnalysis("nested dc") }
      let start = try Self.numericValue(spec.startValue, field: "dc.start")
      let stop = try Self.numericValue(spec.stopValue, field: "dc.stop")
      let step = try Self.numericValue(spec.stepValue, field: "dc.step")
      guard step != 0 else { throw CLIError.invalidArguments("dc sweep step cannot be zero") }
      let schedule: [Double]
      do {
        schedule = try SPICEDCSweepSchedule.values(from: start, through: stop, by: step,
          maximumCount: min(policy.maximumElements, phaseCollector == nil ? policy.maximumElements : 10_000))
      } catch let failure as SPICEDCSweepSchedule.Failure {
        switch failure {
        case .invalidDirection: throw CoreSpiceCLICaseError.incompleteOutput("Invalid DC sweep direction")
        case .pointLimit: throw CoreSpiceCLICaseError.incompleteOutput("DC phase budget exceeded")
        case .nonAdvancingPoint: throw CoreSpiceCLICaseError.incompleteOutput("DC schedule cannot advance")
        }
      }
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
      dcSweepResult = run.result
      waveform = .from(sweepResult: run.result, topology: plan.topology.circuitTopology, title: "DC Sweep")
      phases = run.phases
    case .noise(let spec):
      let output = try Self.resolveNode(named: spec.outputNode, plan: plan)
      let reference = try spec.referenceNode.map { try Self.resolveNode(named: $0, plan: plan) }
      let run = try await NoiseAnalysis(outputNode: output, outputReferenceNode: reference,
        inputSourceName: spec.inputSource, sweep: Self.frequencySweep(from: spec), dcConfig: options.convergence, nodeInitialGuess: values.nodeSetVoltages)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = .from(noiseResult: run.result, title: "Noise"); phases = run.phases
      operatingPoint = run.result.operatingPoint; noise = run.result
    case .transferFunction(let spec):
      let run = try await TransferFunctionAnalysis(outputNode: Self.resolveVoltageOutput(spec.output, plan: plan),
        inputSourceName: spec.input, dcConfig: options.convergence)
        .run(circuit: owner, solver: solver, observer: nil, cancellation: cancellation)
      waveform = .from(transferFunctionResult: run.result, title: "Transfer Function"); phases = run.phases
    case .sensitivity:
      throw CLIError.state("Sensitivity requires the captured source execution path")
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
      poleZeroResult = filtered
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
    if case .op = analysis, let operatingPoint, operatingPoint.opticalState == nil, operatingPoint.variableLowComponents != nil {
      completedNativeDCResult = try .init(operatingPoint: operatingPoint)
    } else if let dcSweepResult, dcSweepResult.results.allSatisfy({ $0.opticalState == nil }), dcSweepResult.results.contains(where: { $0.variableLowComponents != nil }) {
      completedNativeDCResult = try .init(sweep: dcSweepResult)
    }
    let collectPhases: Bool
    if case .dc = analysis { collectPhases = false } else { collectPhases = true }
    try retain(phases, record: record, waveform: waveform, prefix: phasePrefix, collectPhases: collectPhases, poleZeroResult: poleZeroResult, operatingPoint: operatingPoint, transient: transient, noise: noise)
    return waveform
  }

  private mutating func runSourceAnalysis(at index: Int,
                                            phasePrefix: String, cancellation: CancellationToken) async throws -> WaveformData {
    guard let deck = accountedSourceDeck else { throw CLIError.state("Missing captured source graph") }
    let resources = try policy.resources()
    let catalog = try CoreSpiceCLICapturedSourceCatalog(deck, resources: resources)
    let input = try await CoreSpicePreparedCommand.prepareInput(sources: catalog.sources, routes: catalog.routes,
      policy: policy, osdiCatalog: osdiCatalog, resources: resources, analysisIndex: index, seed: loadedSeed,
      networkSelection: networkOptions?.analysisIndex == index ? try networkOptions?.selection(policy: policy) : nil)
    // Transfer the compiled graph and its admission together before foreign child preparations coexist.
    plan = nil; compiled = input.lowered.compiled; sourcePreparedInput = input; resolved = nil
    if numericalExecutionResources == nil {
      numericalExecutionResources = try .init(limits: input.configuration.numericalLimits)
    }
    let output = try await CoreSpicePreparedCommand.execute(input: input, policy: policy,
      osdiCatalog: osdiCatalog, cancellation: cancellation, executionResources: numericalExecutionResources)
    let completion = try CoreSpiceCLISourceCompletion(output, numericalResources: numericalExecutionResources, cancellation: cancellation)
    completedSourceCompletion = completion
    if output.networkResult != nil {
      completedNetworkCase = try .init(index: 0, output: output, completion: completion.record, resources: resources)
    }
    let sensitivity = output.waveform.metadata.analysisType == .sensitivity
    if sensitivity { try phaseCollector?.sensitivity(output, prefix: phasePrefix) }
    try retain(output.phases, record: output.prepared.circuitPreparation, waveform: output.waveform,
      prefix: phasePrefix, collectPhases: !sensitivity, operatingPoint: output.operatingPoint,
      compiledOverride: output.prepared.input.lowered.compiled)
    let kind = output.networkResult == nil ? (sensitivity ? "sensitivity" : "tf") : "network"
    try phaseCollector?.sourceCompletion(completion, id: phasePrefix + "source-" + kind,
      metricPrefix: phasePrefix + kind + ":")
    return output.waveform
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

  private func requireAllMeasurements(_ results: [SPICEMeasurementResult]) throws {
    for control in parsedNetlist?.controls ?? [] {
      guard case .measure(let measure) = control else { continue }
      guard results.contains(where: { $0.name == measure.resultName && $0.analysisType == measure.analysisType }) else {
        throw CLIError.invalidArguments("Requested measurement '\(measure.resultName)' has no completed \(measure.analysisType.rawValue) analysis")
      }
    }
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
