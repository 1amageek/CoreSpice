import CoreSpiceIR

/// Device noise preserving complex correlation through full-node transfer values.
public protocol OutputReferredNoisyDevice: BoundDevice {
    /// Stable physical/owned nodes needed to evaluate all original channels.
    var noiseTransferNodes: [Node] { get }
    /// Returns stable named output channels; no independent-PSD duplicate is added.
    func outputNoiseContributions(state: SolutionState, frequency: Double,
                                  gains: NoiseTransferGains) throws -> [OutputNoiseSource]
}
