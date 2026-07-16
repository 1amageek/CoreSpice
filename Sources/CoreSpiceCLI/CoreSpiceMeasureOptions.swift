import Foundation

/// Parsed arguments for the `corespice measure` subcommand.
///
/// ```
/// corespice measure --waveform <path.csv> --measure "<spec>" [--measure "<spec>" ...] [--json]
/// ```
struct CoreSpiceMeasureOptions {
  /// Path of the waveform CSV to measure.
  let waveformPath: String
  /// Measurement specs in `.measure` grammar without the leading `.measure`
  /// (e.g. `tran vfinal FIND V(out) AT=5u`), in command-line order.
  let specs: [String]
  /// Whether to emit a machine-readable JSON record on stdout.
  let jsonOutput: Bool

  /// A normalized command-line representation suitable for replay.
  var invocationArguments: [String] {
    var arguments = ["measure", "--waveform", waveformPath]
    for spec in specs {
      arguments += ["--measure", spec]
    }
    if jsonOutput {
      arguments.append("--json")
    }
    return arguments
  }

  init(arguments: [String]) throws {
    var cursor = CoreSpiceCLIArgumentCursor(arguments: arguments)
    var waveformPath: String?
    var specs: [String] = []
    var jsonOutput: Bool?

    while !cursor.isAtEnd {
      let argument = cursor.current
      switch argument {
      case "--waveform":
        try Self.rejectDuplicate(waveformPath, argument: argument)
        waveformPath = try cursor.nonOptionValue(after: argument)
      case "--measure":
        specs.append(try cursor.nonOptionValue(after: argument))
      case "--json":
        try Self.rejectDuplicate(jsonOutput, argument: argument)
        jsonOutput = true
        cursor.advance()
      default:
        throw CLIError.invalidArguments("unknown measure argument: \(argument)")
      }
    }

    guard let waveformPath else {
      throw CLIError.invalidArguments("measure requires --waveform <path.csv>")
    }
    guard !specs.isEmpty else {
      throw CLIError.invalidArguments("measure requires at least one --measure \"<spec>\"")
    }

    self.waveformPath = waveformPath
    self.specs = specs
    self.jsonOutput = jsonOutput ?? false
  }

  private static func rejectDuplicate<T>(_ value: T?, argument: String) throws {
    if value != nil {
      throw CLIError.invalidArguments("duplicate argument: \(argument)")
    }
  }
}
