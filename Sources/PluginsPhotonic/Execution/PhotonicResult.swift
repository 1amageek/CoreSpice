import Foundation

/// Complex output amplitude for a single port.
public struct PhotonicPortOutput: Sendable {

    /// Index of the output port (0--511).
    public let portIndex: Int

    /// Real part of the complex amplitude.
    public let real: Float

    /// Imaginary part of the complex amplitude.
    public let imag: Float

    /// Optical power (magnitude squared).
    public var power: Float { real * real + imag * imag }

    /// Field amplitude (magnitude).
    public var amplitude: Float { sqrt(power) }

    /// Phase angle in radians.
    public var phase: Float { atan2(imag, real) }

    public init(portIndex: Int, real: Float, imag: Float) {
        self.portIndex = portIndex
        self.real = real
        self.imag = imag
    }
}

/// Result for a single wavelength point, containing all 512 port outputs.
public struct PhotonicWavelengthResult: Sendable {

    /// The wavelength at which this result was computed.
    public let wavelength: Double

    /// Complex output amplitudes for all ports.
    public let outputs: [PhotonicPortOutput]

    public init(wavelength: Double, outputs: [PhotonicPortOutput]) {
        self.wavelength = wavelength
        self.outputs = outputs
    }

    /// Sum of optical power across all output ports.
    public var totalOutputPower: Float {
        outputs.reduce(Float(0)) { $0 + $1.power }
    }
}

/// Aggregate result of a photonic mesh simulation.
public struct PhotonicResult: Sendable {

    /// Per-wavelength simulation results.
    public let wavelengthResults: [PhotonicWavelengthResult]

    /// Number of layers in the simulated mesh.
    public let meshLayerCount: Int

    /// Number of ports in the mesh (typically 512).
    public let portCount: Int

    public init(
        wavelengthResults: [PhotonicWavelengthResult],
        meshLayerCount: Int,
        portCount: Int = 512
    ) {
        self.wavelengthResults = wavelengthResults
        self.meshLayerCount = meshLayerCount
        self.portCount = portCount
    }
}
