import Foundation

struct CoreSpiceCLIArgumentCursor {
  let arguments: [String]
  private(set) var index: Int = 0

  var isAtEnd: Bool {
    index >= arguments.count
  }

  var current: String {
    arguments[index]
  }

  mutating func advance() {
    index += 1
  }

  mutating func value(after argument: String) throws -> String {
    advance()
    return try nextValue(for: argument)
  }

  mutating func nextValue(for argument: String) throws -> String {
    guard index < arguments.count else {
      throw CLIError.invalidArguments("missing value after \(argument)")
    }
    let value = arguments[index]
    index += 1
    return value
  }

  mutating func nonOptionValue(after argument: String) throws -> String {
    let value = try value(after: argument)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIError.invalidArguments("empty value after \(argument)")
    }
    guard !Self.isOptionToken(value) else {
      throw CLIError.invalidArguments("missing value after \(argument)")
    }
    return value
  }

  mutating func nextNonOptionValue(for argument: String) throws -> String {
    let value = try nextValue(for: argument)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIError.invalidArguments("empty value after \(argument)")
    }
    guard !Self.isOptionToken(value) else {
      throw CLIError.invalidArguments("missing value after \(argument)")
    }
    return value
  }

  mutating func spiceNumber(after argument: String, expected: String) throws -> Double {
    let rawValue = try value(after: argument)
    return try Self.parseStrictSPICENumber(rawValue, argument: argument, expected: expected)
  }

  mutating func nextSPICENumber(for argument: String, expected: String) throws -> Double {
    let rawValue = try nextValue(for: argument)
    return try Self.parseStrictSPICENumber(rawValue, argument: argument, expected: expected)
  }

  private static func parseStrictSPICENumber(
    _ rawValue: String,
    argument: String,
    expected: String
  ) throws -> Double {
    guard let value = parseSPICENumber(rawValue) else {
      throw CLIError.invalidArguments("\(argument) expects \(expected), got '\(rawValue)'")
    }
    return value
  }

  static func isOptionToken(_ value: String) -> Bool {
    if value.hasPrefix("--") {
      return true
    }
    if value.hasPrefix("-"), parseSPICENumber(value) == nil {
      return true
    }
    return false
  }
}
