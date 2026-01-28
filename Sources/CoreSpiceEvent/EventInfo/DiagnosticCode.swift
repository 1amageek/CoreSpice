public enum DiagnosticCode: String, Sendable, Codable {
    case nanDetected
    case infDetected
    case convergenceStall
    case matrixSingular
    case negativeConductance
    case timestepTooSmall
    case breakpointMissed
    case gpuFallback
    case bufferOverflow
}
