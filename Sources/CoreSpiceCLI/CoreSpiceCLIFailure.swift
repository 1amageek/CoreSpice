import CoreSpiceLowering
import CoreSpiceMOSResolution
import CoreSpice
import CoreSpiceCompile
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts
import CoreSpiceDevices
import CoreSpiceExporterCSV
import CoreSpiceIO
import Foundation

/// Structured failure emitted when a JSON-mode CLI operation cannot complete.
public struct CoreSpiceCLIFailure: Codable, Sendable, Hashable {
  public let status: String
  public let code: String
  public let message: String
  public let stage: String?
  public let suggestedActions: [String]?

  public init(
    code: String,
    message: String,
    stage: String? = nil,
    suggestedActions: [String]? = nil
  ) {
    self.status = "failed"
    self.code = code
    self.message = message
    self.stage = stage
    self.suggestedActions = suggestedActions
  }
}

// MARK: - Failure classification

extension CoreSpiceCLIFailure {

  /// Builds a failure record from any error thrown by the CLI pipeline,
  /// deriving a stable code (and stage/actions when possible) from the
  /// typed error.
  init(error: any Error) {
    switch error {
    case let profile as CoreSpiceCLIExecutionProfile.Failure:
      switch profile {
      case .invalidProfile(let reason): self.init(code: "cli.execution-profile", message: reason, stage: "admission")
      case .conflictingPrecisionBudget: self.init(code: "cli.execution-profile", message: "Execution profile conflicts with OSDI precision execution budget", stage: "admission")
      }
    case let osdi as CoreSpiceCLIOSDIError:
      switch osdi {
      case .invalidCatalog(let reason): self.init(code: "osdi.catalog", message: reason, stage: "admission")
      case .unsupportedAnalysis(let name): self.init(code: "osdi.unsupported-analysis", message: name, stage: "admission")
      case .incompleteReceipt(let reason): self.init(code: "osdi.incomplete-receipt", message: reason, stage: "execution")
      }

    case let verification as NativePrecisionConfigurationVerification.Failure:
      switch verification {
      case .resource(let cause): self.init(error: cause)
      case .identityMismatch: self.init(code: "osdi.incomplete-receipt", message: "Saved precision configuration facts differ from Native commitment", stage: "execution")
      case .invalidFacts(let reason): self.init(code: "osdi.incomplete-receipt", message: reason, stage: "execution")
      }

    case is CancellationError:
      self.init(code: "case.cancelled", message: "Case execution was cancelled", stage: "execution")

    case let caseError as CoreSpiceCLICaseError:
      let code: String
      switch caseError {
      case .missingModelOrigin: code = "case.missing-model-origin"
      case .unrecordedModelConsumption: code = "case.unrecorded-model-consumption"
      case .incompleteOutput: code = "case.incomplete-output"
      case .publication: code = "case.publication"
      case .unsupportedAnalysis: code = "case.unsupported-phase-evidence"
      }
      self.init(code: code, message: caseError.localizedDescription, stage: "case-publication")

    case let diode as DiodeNumericalFailure:
      self.init(code: "diode.numerical", message: Self.describe(diode), stage: "analysis")
    case let diode as DiodePreparationFailure:
      self.init(code: "diode.preparation", message: Self.describe(diode), stage: "preparation")
    case let diode as DiodeSchemaFailure:
      self.init(code: "diode.schema", message: Self.describe(diode), stage: "admission")
    case let diode as DiodeResolutionFailure:
      self.init(code: "diode.resolution", message: "\(diode.instance ?? "diode"): \(diode.cause); source \(diode.assignment?.location?.description ?? "unavailable")", stage: "resolution",
        suggestedActions: ["inspect the explicit diode profile and selected source assignments"])

    case let preparation as SPICESimulationPreparationError:
      switch preparation {
      case .condition(let cause, let resourceCause):
        if let resourceCause { self.init(error: resourceCause) }
        else { self.init(error: cause) }
      case .diodeResolution(let cause, let resourceCause, _):
        if let resourceCause { self.init(error: resourceCause) }
        else { self.init(error: cause) }
      case .resolution(let cause, let resourceCause):
        if let resourceCause {
          let failure = Self(error: resourceCause)
          self.init(code: failure.code, message: "\(Self.describe(cause)); \(failure.message)",
            stage: failure.stage, suggestedActions: failure.suggestedActions)
        } else { self.init(error: cause) }
      case .resource(let cause), .source(let cause), .parser(let cause), .lowering(let cause), .options(let cause):
        self.init(error: cause)
      case .nodeVoltage(let cause): self.init(error: cause)
      case .invalidPolicy:
        self.init(code: "preparation.invalid-policy", message: "Invalid source preparation policy", stage: "preparation")
      case .missingAnalysis:
        self.init(code: "preparation.missing-analysis", message: "No source analysis is selected", stage: "preparation")
      case .unsupportedCapability(let detail):
        self.init(code: "preparation.unsupported-capability", message: detail, stage: "preparation")
      case .invalidSupplyBinding(let name):
        self.init(code: "preparation.invalid-supply-binding", message: "Invalid supply binding: \(name)", stage: "preparation")
      case .missingConditionCoverage:
        self.init(code: "preparation.missing-condition-coverage", message: "Required operating condition coverage is unavailable", stage: "preparation")
      case .conditionMismatch:
        self.init(code: "preparation.condition-mismatch", message: "Source operating conditions differ from the required reference", stage: "preparation")
      }

    case let capacity as SPICESimulationCapacityError:
      switch capacity {
      case .elements(let boundary, let limit, let requested):
        self.init(code: "preparation.element-limit",
          message: "\(boundary.rawValue) element limit \(limit) exceeded by request \(requested)", stage: "preparation",
          suggestedActions: ["inspect the source graph and explicitly admitted caller policy"])
      case .transformBytes(let limit, let requested):
        self.init(code: "preparation.transform-byte-limit",
          message: "IO transform capacity limit \(limit) bytes exceeded by request \(requested) bytes", stage: "preparation",
          suggestedActions: ["inspect the IO transform envelope and explicitly admitted caller policy"])
      }

    case let resource as SPICESimulationResources.ResourceError:
      let suffix: String
      switch resource {
      case .invalidPolicy: suffix = "invalid-policy"
      case .workLimit: suffix = "work-limit"
      case .hashLimit: suffix = "hash-limit"
      case .storageLimit: suffix = "storage-limit"
      case .cancelled:
        self.init(code: "analysis.cancelled", message: "Source preparation was cancelled", stage: "admission")
        return
      }
      self.init(code: "invocation.\(suffix)", message: Self.describe(resource), stage: "admission",
        suggestedActions: ["inspect the shared invocation resource policy and retained owners"])

    case let source as SPICEExactSourceError:
      self.init(code: "io.exact-source", message: Self.describe(source), stage: "load",
        suggestedActions: ["inspect the exact source catalog, routes and captured identities"])

    case let storage as SPICESourceStorageError:
      self.init(code: "invocation.storage-integrity", message: Self.describe(storage), stage: "admission")

    case let parse as SPICEProfileParseFailure:
      self.init(error: parse.diagnostic)

    case let source as SPICEBoundedSourceError:
      self.init(code: "deck.source-policy", message: Self.describe(source), stage: "parse")

    case let condition as MOSConditionEvaluationFailure:
      if condition.cause == .cancelled {
        self.init(code: "analysis.cancelled", message: "Temperature evaluation was cancelled", stage: "evaluation")
      } else {
        let source = condition.diagnostic?.conditionSource
        let location = source.map { " at \($0.path ?? "<source>"):\($0.line ?? 0):\($0.column ?? 0)" } ?? ""
        self.init(code: "evaluation.temperature", message: String(describing: condition.cause) + location, stage: "evaluation")
      }
    case let preparation as SPICENativePreparationError:
      switch preparation {
      case .osdi(let cause): self.init(code: "osdi.preparation", message: Self.describe(cause), stage: "preparation")
      case .osdiCleanup(let cause): self.init(code: "osdi.cleanup", message: Self.describe(cause), stage: "preparation")
      case .compile(let cause), .binding(let cause), .resource(let cause): self.init(error: cause)
      case .diodePreparation(let cause): self.init(code: "diode.preparation", message: Self.describe(cause), stage: "preparation")
      case .mosPreparation(let cause): self.init(code: "mos.preparation", message: Self.describe(cause), stage: "preparation")
      case .mosBinding(let cause): self.init(code: "mos.binding", message: Self.describe(cause), stage: "preparation")
      case .evaluationEnvironment: self.init(code: "native.environment-mismatch", message: "Operating conditions differ from source evaluation", stage: "preparation")
      case .invalidLimits, .capacityExceeded: self.init(code: "preparation.capacity", message: Self.describe(preparation), stage: "preparation")
      case .unsupportedCapability(let detail): self.init(code: "preparation.unsupported-capability", message: detail, stage: "preparation")
      }

    case let network as NetworkParameterError:
      self.init(code: "analysis.network-parameters", message: Self.describe(network), stage: "analysis",
        suggestedActions: ["inspect the selected voltage-source boundaries, positive frequencies, reference resistances and RF resource policy"])

    case let physical as SPICEOSDIPhysicalResidualFailure:
      let kind: String
      let unit: String
      switch physical.kind {
      case .electricalPotential: kind = "electricalPotential"; unit = "A"
      case .electricalFlow: kind = "electricalFlow"; unit = "V"
      case .thermalPotential: kind = "thermalPotential"; unit = "W"
      }
      self.init(code: "analysis.physical-residual",
        message: "Original physical equation gate failed at row \(physical.row) (\(kind)): residual \(physical.residual) \(unit), absolute tolerance \(physical.absoluteTolerance) \(unit)",
        stage: "analysis", suggestedActions: ["inspect the original equation, selected model inputs and operating conditions at the reported row"])

    case let nativeError as SPICENativeExecutionError:
      switch nativeError {
      case .osdi(let cause): self.init(code: "osdi.execution", message: Self.describe(cause), stage: "analysis")
      case .osdiCleanup(let cause): self.init(code: "osdi.cleanup", message: Self.describe(cause), stage: "analysis")
      case .numerical(let cause), .binding(let cause), .resource(let cause): self.init(error: cause)
      case .cancelled: self.init(code: "analysis.cancelled", message: "Native execution was cancelled", stage: "analysis")
      case .mosPreparation(let cause): self.init(code: "mos.preparation", message: Self.describe(cause), stage: "preparation")
      case .unsupportedCapability(let detail): self.init(code: "analysis.unsupported-capability", message: detail, stage: "analysis")
      case .invalidOutput: self.init(code: "analysis.invalid-output", message: "Native execution produced invalid output", stage: "analysis")
      }

    case MOSResolutionFailure.cancelled:
      self.init(code: "analysis.cancelled", message: "Source evaluation was cancelled", stage: "lower")

    case let nodeError as SPICENodeVoltageResolutionError:
      if case .evaluation(_, let cause) = nodeError { self.init(error: cause) }
      else { self.init(code: "deck.node-voltage", message: Self.describe(nodeError), stage: "lower") }

    case MOSSchemaFailure.osdiBindingRequired(let level, let version):
      self.init(code: "mos.osdi-binding-required",
        message: "MOS level \(level) version \(version ?? "unspecified") requires an explicit OSDI catalog/model binding",
        stage: "lower", suggestedActions: ["provide an OSDI catalog and bind the external model"])

    case let failure as MOSResolutionFailure:
      if case .osdiBindingRequired(let level, let version, let source) = failure {
        let location = (source.path ?? source.captureID ?? "captured source") + ":" +
          (source.line.map(String.init) ?? "unknown") + ":" + (source.column.map(String.init) ?? "unknown")
        self.init(code: "mos.osdi-binding-required",
          message: "MOS level \(level) version \(version ?? "unspecified") requires an explicit OSDI catalog/model binding at \(location)",
          stage: "lower", suggestedActions: ["provide an OSDI catalog and bind the external model"])
      } else {
        self.init(code: "mos.resolution", message: Self.describe(failure), stage: "lower")
      }

    case let cliError as CLIError:
      self.init(cliError: cliError)

    case let captureError as SPICESourceCaptureError:
      let code: String
      let actions: [String]
      switch captureError {
      case .invalidPolicy, .totalByteLimitExceeded, .sourceCountLimitExceeded:
        code = "io.source-capture-budget"
        actions = ["inspect the effective source capture policy and graph size"]
      case .invalidUTF8:
        code = "io.source-encoding"
        actions = ["provide a valid UTF-8 SPICE source"]
      case .readFailed:
        code = "io.file-read"
        actions = ["verify that the deck path exists and is readable"]
      case .sourceChangedDuringRead:
        code = "io.source-changed"
        actions = ["retry with an immutable source graph"]
      case .closeFailed, .cleanupFailed:
        code = "io.source-close"
        actions = ["inspect the source read and close failure before retrying"]
      }
      self.init(code: code, message: Self.describe(captureError), stage: "load", suggestedActions: actions)

    case let diagnostic as ParserDiagnostic:
      self.init(
        code: "deck.parse",
        message: diagnostic.description,
        stage: "parse",
        suggestedActions: ["fix the reported syntax error in the deck"]
      )

    case let loweringError as LoweringError:
      if case .invalidOSDIInput = loweringError {
        self.init(code: loweringError.diagnostic.code, message: Self.describe(loweringError), stage: "lower")
      } else {
        self.init(code: "deck.lower", message: Self.describe(loweringError), stage: "lower")
      }

    case let optionError as SPICEAnalysisOptionError:
      self.init(
        code: "deck.analysis-options",
        message: Self.describe(optionError),
        stage: "lower"
      )

    case let loadError as SPICEDeckLoadError:
      switch loadError {
      case .fileRead:
        self.init(
          code: "io.file-read",
          message: Self.describe(loadError),
          stage: "load",
          suggestedActions: [
            "verify that the deck path exists and is readable"
          ]
        )
      case .blockedExecutionIntent:
        self.init(
          code: "deck.blocked-intent",
          message: Self.describe(loadError),
          stage: "parse",
          suggestedActions: [
            "remove or replace execution-blocking directives reported by deck coverage"
          ]
        )
      }

    case let compileError as CompileError:
      self.init(
        code: "compile.failed",
        message: Self.describe(compileError),
        stage: "compile"
      )

    case let bindingError as DeviceBindingError:
      self.init(
        code: "compile.device-binding",
        message: Self.describe(bindingError),
        stage: "compile"
      )

    case let budgetError as TransientExecutionError:
      self.init(code: "analysis.transient-execution", message: budgetError.description, stage: "analysis")

    case let waveformError as WaveformError:
      self.init(code: "analysis.waveform-admission", message: Self.describe(waveformError), stage: "analysis")

    case let analysisError as AnalysisError:
      self.init(analysisError: analysisError)

    case let resultError as TransientResultError:
      self.init(
        code: "analysis.result",
        message: Self.describe(resultError),
        stage: "analysis"
      )

    case let validationError as WaveformValidationError:
      self.init(
        code: "waveform.validation",
        message: Self.describe(validationError),
        stage: "analysis"
      )

    case let validationError as ParametricWaveformValidationError:
      self.init(
        code: "waveform.validation",
        message: Self.describe(validationError),
        stage: "analysis"
      )

    case let measurementError as SPICEMeasurementError:
      self.init(
        code: "measure.evaluation",
        message: Self.describe(measurementError),
        stage: "measure"
      )

    case let projectionError as SPICEOutputProjectionError:
      self.init(
        code: "output.projection",
        message: Self.describe(projectionError),
        stage: "export",
        suggestedActions: [
          "correct .save, .probe, .print, or .plot variables to match generated waveform names"
        ]
      )

    case let measureCommandError as CoreSpiceMeasureCommandError:
      self.init(measureCommandError: measureCommandError)

    case let readError as CSVWaveformReadError:
      self.init(
        code: "waveform.csv-read",
        message: Self.describe(readError),
        stage: "load",
        suggestedActions: [
          "check that the file is a waveform CSV written by the CoreSpice CSV exporter"
        ]
      )

    case let exporterError as ExporterError:
      self.init(
        code: "export.write",
        message: Self.describe(exporterError),
        stage: "export"
      )

    default:
      self.init(unclassified: error)
    }
  }

  private init(cliError: CLIError) {
    let usageHint = ["run 'corespice --help' to review usage"]
    switch cliError {
    case .invalidArguments:
      self.init(
        code: "cli.invalid-arguments",
        message: Self.describe(cliError),
        stage: "arguments",
        suggestedActions: usageHint
      )
    case .unknownCommand:
      self.init(
        code: "cli.unknown-command",
        message: Self.describe(cliError),
        stage: "arguments",
        suggestedActions: usageHint
      )
    case .state:
      self.init(code: "cli.state", message: Self.describe(cliError))
    case .unsupportedAnalysis:
      self.init(
        code: "cli.unsupported-analysis",
        message: Self.describe(cliError),
        stage: "analysis",
        suggestedActions: [
          "run the deck with an explicit --op, --tran, --ac, or --dc override"
        ]
      )
    case .missingAnalysisDirective:
      self.init(
        code: "cli.missing-analysis-directive",
        message: Self.describe(cliError),
        stage: "analysis",
        suggestedActions: [
          "add an explicit .op, .dc, .ac, or .tran directive to the deck",
          "or pass an analysis override flag (--op, --tran, --ac, --dc)"
        ]
      )
    }
  }

  private init(measureCommandError: CoreSpiceMeasureCommandError) {
    switch measureCommandError {
    case .specParseFailed, .specNotSingleMeasurement:
      self.init(
        code: "measure.spec-parse",
        message: Self.describe(measureCommandError),
        stage: "parse",
        suggestedActions: [
          "write the spec in .measure grammar without the leading '.measure', starting with tran, ac, dc, or op"
        ]
      )
    case .analysisDomainMismatch:
      self.init(
        code: "measure.analysis-mismatch",
        message: Self.describe(measureCommandError),
        stage: "measure",
        suggestedActions: [
          "declare the analysis type matching the waveform sweep variable (time -> tran, frequency -> ac, otherwise dc)"
        ]
      )
    case .evaluationFailed:
      self.init(
        code: "measure.evaluation",
        message: Self.describe(measureCommandError),
        stage: "measure"
      )
    }
  }

  private init(analysisError: AnalysisError) {
    let code: String
    var suggestedActions: [String]? = nil
    switch analysisError {
    case .convergenceFailure:
      code = "analysis.convergence-failure"
      suggestedActions = [
        "generate a recovery plan with 'corespice convergence-recovery-objective'"
      ]
    case .nonFiniteSolution:
      code = "analysis.non-finite-solution"
      suggestedActions = [
        "inspect device parameters and matrix scaling near the reported variable"
      ]
    case .nonFiniteResidual:
      code = "analysis.non-finite-residual"
      suggestedActions = [
        "inspect nonlinear device stamps near the reported variable"
      ]
    case .singularMatrix:
      code = "analysis.singular-matrix"
    case .cancelled:
      code = "analysis.cancelled"
    case .invalidConfiguration:
      code = "analysis.invalid-configuration"
    case .timestepTooSmall:
      code = "analysis.timestep-too-small"
    case .unsupportedPoleZeroDevice:
      code = "analysis.pole-zero-applicability"
    case .requiresFreshMOSResolution:
      code = "analysis.requires-fresh-mos-resolution"
      suggestedActions = ["resolve the original source with fresh parameters and a new evaluation session"]
    case .internalError:
      code = "analysis.internal"
    }
    self.init(
      code: code,
      message: Self.describe(analysisError),
      stage: "analysis",
      suggestedActions: suggestedActions
    )
  }

  /// Fallback classification for errors without a dedicated typed mapping.
  /// Foundation file-system errors are recognized by domain so missing or
  /// unwritable paths still produce actionable codes.
  private init(unclassified error: any Error) {
    let nsError = error as NSError
    switch nsError.domain {
    case NSCocoaErrorDomain:
      self.init(cocoaError: nsError)
    case NSPOSIXErrorDomain:
      self.init(
        code: "io.posix",
        message: nsError.localizedDescription,
        stage: nil
      )
    default:
      self.init(
        code: "internal.unhandled",
        message: Self.describe(error)
      )
    }
  }

  private init(cocoaError nsError: NSError) {
    // NSFileNoSuchFileError and the NSFileRead* range cover unreadable inputs;
    // the NSFileWrite* ranges cover unwritable outputs.
    switch nsError.code {
    case NSFileNoSuchFileError, NSFileReadUnknownError...NSFileReadUnknownStringEncodingError:
      self.init(
        code: "io.file-read",
        message: nsError.localizedDescription,
        stage: "load",
        suggestedActions: ["check that the input path exists and is readable"]
      )
    case NSFileWriteUnknownError...NSFileWriteUnsupportedSchemeError,
      NSFileWriteOutOfSpaceError,
      NSFileWriteVolumeReadOnlyError:
      self.init(
        code: "io.file-write",
        message: nsError.localizedDescription,
        stage: "export",
        suggestedActions: ["check that the output path is writable"]
      )
    default:
      self.init(
        code: "io.cocoa",
        message: nsError.localizedDescription
      )
    }
  }

  /// Prefers `LocalizedError.errorDescription`, then the default description
  /// (which routes through `CustomStringConvertible` when conformed).
  private static func describe(_ error: any Error) -> String {
    if let localized = error as? LocalizedError, let text = localized.errorDescription {
      return text
    }
    return String(describing: error)
  }
}
