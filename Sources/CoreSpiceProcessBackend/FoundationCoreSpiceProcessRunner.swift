import Foundation
import SignoffToolSupport

public actor FoundationCoreSpiceProcessRunner: CoreSpiceProcessRunning {
    private let processRunner: any TimedProcessRunning
    private var isRunning = false

    public init(
        processRunner: any TimedProcessRunning = TimedProcessRunner(maximumOutputByteCount: 64 * 1024 * 1024, cleanupTimeoutSeconds: 2)
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
                control: nil
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
            switch error {
            case .executionFailed(let original):
                var failure = original
                if let handle = original.cleanupHandle {
                    do { try await handle.close(timeoutSeconds: 2) }
                    catch {
                        failure = TimedProcessFailure(executablePath: original.executablePath, cause: original.cause,
                            standardOutputData: original.standardOutputData, standardErrorData: original.standardErrorData,
                            cleanupIssue: "\(original.cleanupIssue ?? "pending"); retry: \(error)", cleanupHandle: handle)
                    }
                }
                do { try persist(standardOutput: failure.standardOutputData,
                    standardError: failure.standardErrorData, invocation: invocation) }
                catch { throw CoreSpiceProcessBackendError.processFailurePersistenceFailed(failure,
                    reason: String(describing: error)) }
                throw CoreSpiceProcessBackendError.processExecutionFailed(failure)
            case .launchFailed(_, let message), .invalidConfiguration(let message):
                throw CoreSpiceProcessBackendError.processLaunchFailed(message)
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
