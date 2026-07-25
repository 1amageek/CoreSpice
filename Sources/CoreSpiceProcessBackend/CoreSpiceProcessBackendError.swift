import CircuiteFoundation
import Foundation

public enum CoreSpiceProcessBackendError: Error, Sendable, Equatable, LocalizedError {
    case invalidExecutable(String)
    case invalidRunRoot(String)
    case missingRandomSeed
    case primaryInputNotFound(ArtifactID)
    case ambiguousPrimaryInput(candidateCount: Int)
    case inputLocationInvalid(ArtifactID, reason: String)
    case inputIntegrityFailed(ArtifactID, issues: [ArtifactIntegrityIssue])
    case concurrentProcessExecution
    case processLaunchFailed(String)
    case processTerminationFailed(String)
    case processFailed(status: Int32, code: String?, message: String, stage: String?)
    case malformedProcessOutput(String)
    case unexpectedInputArtifacts
    case outputOutsideRunDirectory(String)
    case outputIntegrityFailed(ArtifactID, issues: [ArtifactIntegrityIssue])
    case artifactReferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable(let path):
            return "The CoreSpice executable is not an executable regular file: \(path)"
        case .invalidRunRoot(let path):
            return "The CoreSpice run root must be an absolute file URL: \(path)"
        case .missingRandomSeed:
            return "Production CoreSpice executions require an explicit random seed for reproducibility."
        case .primaryInputNotFound(let identifier):
            return "The primary CoreSpice input was not found: \(identifier)"
        case .ambiguousPrimaryInput(let candidateCount):
            return "CoreSpice requires one explicit primary input when \(candidateCount) SPICE inputs exist."
        case .inputLocationInvalid(let identifier, let reason):
            return "CoreSpice input \(identifier) has an invalid location: \(reason)"
        case .inputIntegrityFailed(let identifier, let issues):
            return "CoreSpice input \(identifier) failed integrity verification: \(issues)"
        case .concurrentProcessExecution:
            return "The process runner is already executing another CoreSpice process."
        case .processLaunchFailed(let reason):
            return "CoreSpice could not be launched: \(reason)"
        case .processTerminationFailed(let reason):
            return "CoreSpice process output could not be finalized: \(reason)"
        case .processFailed(let status, let code, let message, let stage):
            let codeDescription = code.map { " [\($0)]" } ?? ""
            let stageDescription = stage.map { " during \($0)" } ?? ""
            return "CoreSpice exited with status \(status)\(stageDescription)\(codeDescription): \(message)"
        case .malformedProcessOutput(let reason):
            return "CoreSpice returned malformed JSON output: \(reason)"
        case .unexpectedInputArtifacts:
            return "CoreSpice consumed inputs that do not exactly match the declared request inputs."
        case .outputOutsideRunDirectory(let path):
            return "CoreSpice reported an output outside its isolated run directory: \(path)"
        case .outputIntegrityFailed(let identifier, let issues):
            return "CoreSpice output \(identifier) failed integrity verification: \(issues)"
        case .artifactReferenceFailed(let reason):
            return "CoreSpice could not create an evidence artifact reference: \(reason)"
        }
    }
}
