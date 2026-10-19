import Foundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO

/// Deterministic JSON serialization for the public CLI records.
public enum CoreSpiceCLIJSON {
  /// Decodes RF evidence under one caller-owned verification invocation, including all family members.
  /// The caller separately admits encoded bytes and decoded-value retention before invoking decode.
  /// Default JSONDecoder intentionally cannot import RF completion mathematics without this context.
  public static func networkDecoder(numericalResources: AnalysisExecutionResources,
                                    sourceResources: any SPICESourceResourceAccounting,
                                    cancellation: CancellationToken = .init()) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[CoreSpiceCLINetworkVerification.key] = CoreSpiceCLINetworkVerification(
      numerical: numericalResources, source: sourceResources, cancellation: cancellation)
    return decoder
  }

  public static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )
    let nativeDC: CoreSpice.SPICENativeStoredDCResult?
    if let batch = value as? CoreSpiceCLIBatchRunRecord { nativeDC = batch.nativeDCResult }
    else if let prepared = value as? CoreSpiceCLIPreparedRunRecord { nativeDC = prepared.nativeDCResult }
    else { nativeDC = nil }
    if let nativeDC {
      return try nativeDC.withSerialization {
        let bytes = try encoder.encode(value)
        if value is CoreSpiceCLIBatchRunRecord { _ = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: bytes) }
        else { _ = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes) }
        return String(decoding: bytes, as: UTF8.self)
      }
    }
    let execution: CoreSpiceCLIOSDIExecutionRecord?
    let models: [CoreSpiceCLIOSDIRecord]?
    if let batch = value as? CoreSpiceCLIBatchRunRecord { execution = batch.osdiExecution; models = batch.osdiModels }
    else if let prepared = value as? CoreSpiceCLIPreparedRunRecord { execution = prepared.osdiExecution; models = prepared.osdiModels }
    else { execution = nil; models = nil }
    guard let execution, let precision = execution.precision else {
      return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    let upper = try completeUpperBound(value, execution: execution, precision: precision, models: models)
    return try precision.withSerialization(upperBound: upper) {
      let bytes = try encoder.encode(value)
      guard UInt64(bytes.count) <= precision.executionBudget.maximumEvidenceBytes else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Encoded precision JSON exceeds caller ceiling")
      }
      // The production persistence boundary validates the same complete saved representation.
      if value is CoreSpiceCLIBatchRunRecord { _ = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: bytes) }
      else { _ = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes) }
      return String(decoding: bytes, as: UTF8.self)
    }
  }
  /// Bound variable envelope metadata before JSONEncoder can materialize it.
  static func completeUpperBound<T>(_ value: T, execution: CoreSpiceCLIOSDIExecutionRecord,
                                   precision: CoreSpiceCLIPrecisionExecution,
                                   models: [CoreSpiceCLIOSDIRecord]?) throws -> UInt64 {
    var upper = try precision.serializedUpperBound(execution: execution, models: models)
    func text(_ value: String?) throws {
      guard let value else { return }
      upper = try CoreSpiceCLIPrecisionExecution.add(upper,
        CoreSpiceCLIPrecisionExecution.add(128, CoreSpiceCLIPrecisionExecution.multiply(UInt64(value.utf8.count), 6)))
    }
    if let batch = value as? CoreSpiceCLIBatchRunRecord {
      guard batch.diodeModels.isEmpty else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision envelope contains unsupported legacy model evidence")
      }
      try text(batch.solverIdentity)
      try text(batch.resolutionProfile); try text(batch.diodeResolutionProfile); try text(batch.resolutionPolicy); try text(batch.status)
      try text(batch.producer.kind.rawValue); try text(batch.producer.identifier); try text(batch.producer.version); try text(batch.producer.build)
      try text(batch.invocation.mode.rawValue); try text(batch.invocation.entryPoint); try text(batch.invocation.executable); try text(batch.invocation.workingDirectory)
      for argument in batch.invocation.arguments { try text(argument) }
      for reference in batch.inputArtifacts + batch.outputArtifacts {
        try text(reference.descriptor.role.rawValue); try text(reference.descriptor.kind.rawValue); try text(reference.descriptor.format.rawValue)
        upper = try CoreSpiceCLIPrecisionExecution.add(upper, 1024)
      }
      for analysis in batch.analyses { try text(analysis) }
      for measurement in batch.measurements {
        try text(measurement.analysis); try text(measurement.name); try text(measurement.unit)
        upper = try CoreSpiceCLIPrecisionExecution.add(upper, 512)
      }
      if let waveform = batch.waveform { for variable in waveform.variables { try text(variable) } }
    } else if let prepared = value as? CoreSpiceCLIPreparedRunRecord {
      guard prepared.diodeModels.isEmpty else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision envelope contains unsupported legacy model evidence")
      }
      try text(prepared.solverIdentity)
    }
    guard upper <= precision.executionBudget.maximumEvidenceBytes else {
      throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete precision envelope exceeds caller ceiling")
    }
    return upper
  }

}
