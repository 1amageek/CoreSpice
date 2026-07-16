import Foundation

enum CoreSpiceValidationFixtureError: Error, Equatable, LocalizedError, Sendable {
    case resourceUnavailable(name: String)

    var errorDescription: String? {
        switch self {
        case let .resourceUnavailable(name):
            return "The packaged CoreSpice validation fixture '\(name)' is unavailable."
        }
    }
}
