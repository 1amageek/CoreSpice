/// Stable occurrence coordinates within the retained compiled input, never a model name alone.
public struct DiodeDeclarationIdentity: Sendable, Hashable {
    public let declaration: UInt64
    public let scope: UInt32
    public let invocation: UInt64
    public let sourcePath: String?
    public let captureID: String?
    public let occurrence: UInt64?
    public let line: Int?
    public let statementOrdinal: UInt64?
    package init(declaration: UInt64, scope: UInt32, invocation: UInt64, sourcePath: String?,
                 captureID: String?, occurrence: UInt64?, line: Int?, statementOrdinal: UInt64?) {
        self.declaration = declaration; self.scope = scope; self.invocation = invocation
        self.sourcePath = sourcePath; self.captureID = captureID; self.occurrence = occurrence
        self.line = line; self.statementOrdinal = statementOrdinal
    }
}
