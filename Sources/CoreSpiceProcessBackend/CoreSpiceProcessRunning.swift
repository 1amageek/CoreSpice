import Foundation

public struct CoreSpiceProcessInvocation: Sendable, Hashable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let standardOutputURL: URL
    public let standardErrorURL: URL

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        standardOutputURL: URL,
        standardErrorURL: URL
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.standardOutputURL = standardOutputURL
        self.standardErrorURL = standardErrorURL
    }
}

public struct CoreSpiceProcessOutput: Sendable, Hashable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        standardOutput: Data,
        standardError: Data
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CoreSpiceProcessRunning: Sendable {
    func run(_ invocation: CoreSpiceProcessInvocation) async throws -> CoreSpiceProcessOutput
}
