/// Invalid waveform evaluation or bounded breakpoint output.
public enum WaveformError: Error, Equatable, Sendable {
    case invalidDomain
    case breakpointLimitExceeded(Int)
    case nonProgressingCycle
}
