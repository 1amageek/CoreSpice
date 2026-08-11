import Foundation
import SignoffToolSupport

public actor FoundationCoreSpiceProcessRunner: CoreSpiceProcessRunning {
    private let processRunner: any TimedProcessRunning
    private var isRunning = false

    public init(
        processRunner: any TimedProcessRunning = TimedProcessRunner()
    ) {
        self.processRunner = processRunner
    }

    public func run(
        _ invocation: CoreSpiceProcessInvocation
    ) async throws -> CoreSpiceProcessOutput {
        guard !isRunning else {
            throw CoreSpiceProcessBackendError.concurrentProcessExecution
        }
        isRunning = true
        defer { isRunning = false }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectoryURL

        do {
            let result = try await processRunner.run(
                process: process,
                cancellationCheck: nil
            )
            try persist(
                standardOutput: result.standardOutputData,
                standardError: result.standardErrorData,
                invocation: invocation
            )
            return CoreSpiceProcessOutput(
                terminationStatus: result.exitCode,
                standardOutput: result.standardOutputData,
                standardError: result.standardErrorData
            )
        } catch let error as TimedProcessError {
            try persist(error: error, invocation: invocation)
            switch error {
            case .cancelled:
                throw CancellationError()
            case .launchFailed(_, let message):
                throw CoreSpiceProcessBackendError.processLaunchFailed(message)
            case .invalidConfiguration(let message):
                throw CoreSpiceProcessBackendError.processLaunchFailed(message)
            case .cancellationCheckFailed(_, let message, _, _):
                throw CoreSpiceProcessBackendError.processTerminationFailed(message)
            case .timedOut(_, let timeoutSeconds, _, _):
                throw CoreSpiceProcessBackendError.processTerminationFailed(
                    "Process timed out after \(timeoutSeconds) seconds."
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CoreSpiceProcessBackendError {
            throw error
        } catch {
            throw CoreSpiceProcessBackendError.processTerminationFailed(
                error.localizedDescription
            )
        }
    }

    private func persist(
        error: TimedProcessError,
        invocation: CoreSpiceProcessInvocation
    ) throws {
        let output: String
        let standardError: String
        switch error {
        case .cancelled(_, let capturedOutput, let capturedError),
             .timedOut(_, _, let capturedOutput, let capturedError),
             .cancellationCheckFailed(_, _, let capturedOutput, let capturedError):
            output = capturedOutput
            standardError = capturedError
        case .invalidConfiguration, .launchFailed:
            output = ""
            standardError = ""
        }
        try persist(
            standardOutput: Data(output.utf8),
            standardError: Data(standardError.utf8),
            invocation: invocation
        )
    }

    private func persist(
        standardOutput: Data,
        standardError: Data,
        invocation: CoreSpiceProcessInvocation
    ) throws {
        do {
            try standardOutput.write(
                to: invocation.standardOutputURL,
                options: .atomic
            )
            try standardError.write(
                to: invocation.standardErrorURL,
                options: .atomic
            )
        } catch {
            throw CoreSpiceProcessBackendError.processTerminationFailed(
                error.localizedDescription
            )
        }
    }
}
