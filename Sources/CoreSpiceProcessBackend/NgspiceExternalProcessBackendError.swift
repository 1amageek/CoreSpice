import CircuiteFoundation
import Foundation

public enum NgspiceExternalProcessBackendError: Error, Sendable, Equatable,
    LocalizedError
{
    case invalidExecutable(String)
    case invalidRunRoot(String)
    case unsupportedRandomSeed
    case primaryInputNotFound(ArtifactID)
    case ambiguousPrimaryInput(candidateCount: Int)
    case inputLocationInvalid(ArtifactID, reason: String)
    case inputIntegrityFailed(ArtifactID, issues: [ArtifactIntegrityIssue])
    case inputStagingFailed(String)
    case processFailed(status: Int32, message: String)
    case missingWaveformOutput(String)
    case artifactReferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable(let path):
            "The ngspice executable is not an executable regular file: \(path)"
        case .invalidRunRoot(let path):
            "The ngspice run root must be an absolute file URL: \(path)"
        case .unsupportedRandomSeed:
            "The ngspice adapter does not claim deterministic random-seed control."
        case .primaryInputNotFound(let identifier):
            "The primary ngspice input was not found: \(identifier)"
        case .ambiguousPrimaryInput(let candidateCount):
            "Ngspice requires one explicit primary input when \(candidateCount) SPICE inputs exist."
        case .inputLocationInvalid(let identifier, let reason):
            "Ngspice input \(identifier) has an invalid location: \(reason)"
        case .inputIntegrityFailed(let identifier, let issues):
            "Ngspice input \(identifier) failed integrity verification: \(issues)"
        case .inputStagingFailed(let reason):
            "Ngspice input staging failed: \(reason)"
        case .processFailed(let status, let message):
            "Ngspice exited with status \(status): \(message)"
        case .missingWaveformOutput(let path):
            "Ngspice did not produce a non-empty waveform at \(path)."
        case .artifactReferenceFailed(let reason):
            "Ngspice output evidence could not be referenced: \(reason)"
        }
    }
}
