import CoreSpiceParsedIR
import Foundation

/// Serializable diagnostic entry for SPICE deck coverage reports.
public struct SPICEDeckCoverageDiagnostic: Sendable, Hashable, Codable {

    public let source: String
    public let code: String
    public let severity: String
    public let message: String
    public let location: SourceLocation?
    public let suggestedActions: [String]
    public let notes: [String]

    public init(
        source: String = "parser",
        code: String? = nil,
        severity: String,
        message: String,
        location: SourceLocation? = nil,
        suggestedActions: [String] = [],
        notes: [String] = []
    ) {
        self.source = source
        self.code = code ?? Self.defaultCode(source: source, severity: severity, message: message)
        self.severity = severity
        self.message = message
        self.location = location
        self.suggestedActions = suggestedActions
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case code
        case severity
        case message
        case location
        case suggestedActions
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decodeIfPresent(String.self, forKey: .source) ?? "parser"
        let severity = try container.decode(String.self, forKey: .severity)
        let message = try container.decode(String.self, forKey: .message)
        self.source = source
        self.code = try container.decodeIfPresent(String.self, forKey: .code)
            ?? Self.defaultCode(source: source, severity: severity, message: message)
        self.severity = severity
        self.message = message
        self.location = try container.decodeIfPresent(SourceLocation.self, forKey: .location)
        self.suggestedActions = try container.decodeIfPresent([String].self, forKey: .suggestedActions) ?? []
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    private static func defaultCode(source: String, severity: String, message: String) -> String {
        let sourceSlug = codeSlug(source, fallback: "diagnostic")
        let severitySlug = codeSlug(severity, fallback: "unspecified")
        let messageSlug = codeSlug(message, fallback: "")
        if messageSlug.isEmpty {
            return "\(sourceSlug)-\(severitySlug)"
        }
        return "\(sourceSlug)-\(severitySlug)-\(messageSlug)"
    }

    private static func codeSlug(_ value: String, fallback: String) -> String {
        var result = ""
        var previousDash = false
        for scalar in value.lowercased().unicodeScalars {
            let scalarValue = scalar.value
            if (48...57).contains(scalarValue) || (97...122).contains(scalarValue) {
                result.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash {
                result.append("-")
                previousDash = true
            }
            if result.count >= 64 {
                break
            }
        }
        let slug = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? fallback : slug
    }
}
