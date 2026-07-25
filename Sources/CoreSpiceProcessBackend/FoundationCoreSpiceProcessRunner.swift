import Foundation

public actor FoundationCoreSpiceProcessRunner: CoreSpiceProcessRunning {
    private var activeProcess: Process?

    public init() {}

    public func run(
        _ invocation: CoreSpiceProcessInvocation
    ) async throws -> CoreSpiceProcessOutput {
        guard activeProcess == nil else {
            throw CoreSpiceProcessBackendError.concurrentProcessExecution
        }
        try Task.checkCancellation()

        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: invocation.standardOutputURL.path, contents: nil) else {
            throw CoreSpiceProcessBackendError.processLaunchFailed(
                "Could not create \(invocation.standardOutputURL.path)."
            )
        }
        guard fileManager.createFile(atPath: invocation.standardErrorURL.path, contents: nil) else {
            throw CoreSpiceProcessBackendError.processLaunchFailed(
                "Could not create \(invocation.standardErrorURL.path)."
            )
        }

        let standardOutputHandle: FileHandle
        let standardErrorHandle: FileHandle
        do {
            standardOutputHandle = try FileHandle(forWritingTo: invocation.standardOutputURL)
            standardErrorHandle = try FileHandle(forWritingTo: invocation.standardErrorURL)
        } catch {
            throw CoreSpiceProcessBackendError.processLaunchFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectoryURL
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle
        activeProcess = process

        let terminationStatus: Int32
        do {
            terminationStatus = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { terminatedProcess in
                        continuation.resume(returning: terminatedProcess.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(
                            throwing: CoreSpiceProcessBackendError.processLaunchFailed(
                                error.localizedDescription
                            )
                        )
                    }
                }
            } onCancel: {
                Task {
                    await self.terminateActiveProcess()
                }
            }
        } catch {
            activeProcess = nil
            try close(standardOutputHandle, standardErrorHandle)
            throw error
        }

        activeProcess = nil
        try close(standardOutputHandle, standardErrorHandle)
        try Task.checkCancellation()

        do {
            return CoreSpiceProcessOutput(
                terminationStatus: terminationStatus,
                standardOutput: try Data(contentsOf: invocation.standardOutputURL),
                standardError: try Data(contentsOf: invocation.standardErrorURL)
            )
        } catch {
            throw CoreSpiceProcessBackendError.processTerminationFailed(
                error.localizedDescription
            )
        }
    }

    private func terminateActiveProcess() {
        guard let activeProcess, activeProcess.isRunning else {
            return
        }
        activeProcess.terminate()
    }

    private func close(_ first: FileHandle, _ second: FileHandle) throws {
        do {
            try first.close()
            try second.close()
        } catch {
            throw CoreSpiceProcessBackendError.processTerminationFailed(
                error.localizedDescription
            )
        }
    }
}
