import CoreSpice
import CoreSpiceCompile
import CoreSpiceMOSContracts
import CoreSpiceDevices
import CoreSpiceCompactModels
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

    case let preparation as SPICENativePreparationError:
      switch preparation {
      case .compile(let cause), .binding(let cause), .resource(let cause): self.init(error: cause)
      case .mosPreparation(let cause): self.init(code: "mos.preparation", message: Self.describe(cause), stage: "preparation")
      case .mosBinding(let cause): self.init(code: "mos.binding", message: Self.describe(cause), stage: "preparation")
      case .invalidLimits, .capacityExceeded: self.init(code: "preparation.capacity", message: Self.describe(preparation), stage: "preparation")
      case .unsupportedCapability(let detail): self.init(code: "preparation.unsupported-capability", message: detail, stage: "preparation")
      }

    case let nativeError as SPICENativeExecutionError:
      switch nativeError {
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

    case let failure as MOSResolutionFailure:
      self.init(code: "mos.resolution", message: Self.describe(failure), stage: "lower")

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
      self.init(
        code: "deck.lower",
        message: Self.describe(loweringError),
        stage: "lower"
      )

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

    case let deviceError as BSIM4DeviceError:
      let suffix: String
      switch deviceError {
      case .missingPreparationPolicy: suffix = "missing-preparation-policy"
      case .missingModel, .modelTypeMismatch: suffix = "model-provenance"
      case .invalidAuxiliaryTopology: suffix = "auxiliary-topology"
      case .transientSessionAlreadyActive, .transientSessionRequired: suffix = "session"
      case .unsupportedAnalysis: suffix = "unsupported-analysis"
      }
      self.init(code: "device.bsim4." + suffix, message: Self.describe(deviceError),
        stage: suffix == "unsupported-analysis" || suffix == "session" ? "analysis" : "prepare")

    case let modelError as BSIM4Error:
      let suffix: String
      switch modelError {
      case .unsupportedVersion: suffix = "version"
      case .invalidConfiguration, .invalidParameter, .modelRejected: suffix = "model-admission"
      case .nonFiniteEvaluation: suffix = "non-finite"
      case .resourceBudgetExceeded: suffix = "preparation-budget"
      case .allocationFailure, .diagnosticCapacityExceeded: suffix = "resources"
      case .invalidHistory: suffix = "history"
      case .noiseNotPrepared: suffix = "noise-not-prepared"
      }
      self.init(code: "device.bsim4." + suffix, message: Self.describe(modelError), stage: "device")

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
