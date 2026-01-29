/// The severity level of a parser diagnostic.
public enum DiagnosticSeverity: String, Sendable, Hashable, Codable, Comparable {

    /// An error that prevents parsing from completing.
    case error

    /// A warning about potentially problematic constructs.
    case warning

    /// Informational note about the parse.
    case info

    /// Hint for improving the netlist.
    case hint

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        let order: [DiagnosticSeverity] = [.hint, .info, .warning, .error]
        guard let lhsIdx = order.firstIndex(of: lhs),
              let rhsIdx = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIdx < rhsIdx
    }
}
