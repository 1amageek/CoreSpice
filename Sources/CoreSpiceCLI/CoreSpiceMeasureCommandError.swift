import Foundation

/// Typed failures raised by the `corespice measure` subcommand.
///
/// Every failing measurement is reported as a structured error naming the
/// spec or the measurement and the reason — a measurement that cannot be
/// evaluated is never silently skipped.
enum CoreSpiceMeasureCommandError: Error, Equatable, LocalizedError {

  /// The measurement spec could not be parsed with the `.measure` grammar.
  case specParseFailed(spec: String, reason: String)

  /// The spec parsed, but did not yield exactly one measurement.
  case specNotSingleMeasurement(spec: String, count: Int)

  /// The measurement declares an analysis domain that does not match the
  /// sweep domain of the loaded waveform.
  case analysisDomainMismatch(measurement: String, declared: String, waveformDomain: String)

  /// The measurement was parsed but could not be evaluated on the waveform.
  case evaluationFailed(measurement: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .specParseFailed(let spec, let reason):
      return "measurement spec '\(spec)' could not be parsed: \(reason)"
    case .specNotSingleMeasurement(let spec, let count):
      return "measurement spec '\(spec)' yielded \(count) measurements, expected exactly 1"
    case .analysisDomainMismatch(let measurement, let declared, let waveformDomain):
      return
        "measurement '\(measurement)' declares analysis '\(declared)' but the waveform is \(waveformDomain)"
    case .evaluationFailed(let measurement, let reason):
      return "measurement '\(measurement)' failed: \(reason)"
    }
  }
}
