import Foundation

/// Deterministic JSON serialization for the public CLI records.
public enum CoreSpiceCLIJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
