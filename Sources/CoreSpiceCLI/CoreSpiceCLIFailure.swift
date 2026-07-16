import CoreSpiceCompile
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
    case let cliError as CLIError:
      self.init(cliError: cliError)

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
    case .singularMatrix:
      code = "analysis.singular-matrix"
    case .cancelled:
      code = "analysis.cancelled"
    case .invalidConfiguration:
      code = "analysis.invalid-configuration"
    case .timestepTooSmall:
      code = "analysis.timestep-too-small"
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
