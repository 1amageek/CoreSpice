public enum SPICENativeExecutionError: Error, Sendable {
    case cancelled
    case numerical(any Error)
    case binding(any Error)
    case resource(any Error)
    case invalidOutput
}
