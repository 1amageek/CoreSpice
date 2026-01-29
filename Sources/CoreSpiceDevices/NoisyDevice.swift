import CoreSpiceIR

/// A noise source contributed by a device.
///
/// Represents a current noise source between two nodes with a given
/// spectral density. The noise analysis uses these to compute the
/// output-referred noise by solving for the transfer function from
/// each noise source to the output.
public struct NoiseSource: Sendable {
    /// A descriptive name for this noise source (e.g., "R1_thermal").
    public let name: String
    /// The positive node of the noise current source.
    public let positiveNode: Node
    /// The negative node of the noise current source.
    public let negativeNode: Node
    /// The current spectral density in A²/Hz.
    public let currentSpectralDensity: Double

    public init(
        name: String,
        positiveNode: Node,
        negativeNode: Node,
        currentSpectralDensity: Double
    ) {
        self.name = name
        self.positiveNode = positiveNode
        self.negativeNode = negativeNode
        self.currentSpectralDensity = currentSpectralDensity
    }
}

/// A device that contributes noise to the circuit.
///
/// Devices conforming to this protocol provide a list of equivalent
/// noise current sources at their terminals. The noise analysis
/// queries each noisy device for its contributions at each frequency
/// point and computes the total output noise spectral density.
public protocol NoisyDevice: BoundDevice {
    /// Returns the noise sources contributed by this device.
    ///
    /// - Parameters:
    ///   - state: The DC operating point solution.
    ///   - frequency: The analysis frequency in Hz.
    /// - Returns: An array of noise current sources.
    func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource]
}
