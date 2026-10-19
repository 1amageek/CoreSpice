/// Explicit host-catalog or completed-evidence refusal.
enum CoreSpiceCLIOSDIError: Error, Sendable {
    case invalidCatalog(String)
    case unsupportedAnalysis(String)
    case incompleteReceipt(String)
}
