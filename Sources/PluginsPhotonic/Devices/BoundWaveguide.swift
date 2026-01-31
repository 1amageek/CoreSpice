import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// A bound waveguide device ready for SPICE-level simulation.
///
/// Like other photonic devices, the waveguide does not contribute
/// to the electrical MNA system in DC/transient modes. In AC mode,
/// it could stamp a complex phase/loss transfer but the primary
/// simulation path is through the photonic mesh executor.
///
/// Also conforms to `OpticalDevice` for optical DAG propagation
/// in mixed-signal optoelectronic simulations.
public struct BoundWaveguide: OpticalDevice, Sendable {

    public let instance: Instance

    /// Physical length of the waveguide in meters.
    public let length: Double

    /// Effective refractive index of the guided mode.
    public let neff: Double

    /// Propagation loss in dB per centimeter.
    public let lossDBPerCm: Double

    /// Optical input node (nil when used in GPU mesh path only).
    private let inputNode: OpticalNode?

    /// Optical output node (nil when used in GPU mesh path only).
    private let outputNode: OpticalNode?

    /// Pre-computed field amplitude transfer coefficient.
    private let fieldAmplitudeTransfer: Double

    /// Pre-computed power transfer coefficient.
    private let powerTransfer: Double

    public var opticalInputNodes: [OpticalNode] {
        if let n = inputNode { return [n] }
        return []
    }

    public var opticalOutputNodes: [OpticalNode] {
        if let n = outputNode { return [n] }
        return []
    }

    public init(
        instance: Instance,
        length: Double,
        neff: Double,
        lossDBPerCm: Double,
        inputNode: OpticalNode? = nil,
        outputNode: OpticalNode? = nil
    ) {
        self.instance = instance
        self.length = length
        self.neff = neff
        self.lossDBPerCm = lossDBPerCm
        self.inputNode = inputNode
        self.outputNode = outputNode

        let lengthCm = length * 100.0
        self.powerTransfer = pow(10.0, -lossDBPerCm * lengthCm / 10.0)
        self.fieldAmplitudeTransfer = pow(10.0, -lossDBPerCm * lengthCm / 20.0)
    }

    // MARK: - OpticalDevice

    public func propagate(inputs: [OpticalNode: OpticalSignal]) -> [OpticalNode: OpticalSignal] {
        guard let inNode = inputNode, let outNode = outputNode,
              let inputSignal = inputs[inNode] else {
            return [:]
        }

        let lambda = inputSignal.wavelength
        let phase = 2.0 * .pi * neff * length / lambda
        let cosPhase = cos(phase)
        let sinPhase = sin(phase)
        let a = fieldAmplitudeTransfer

        let outRe = a * (inputSignal.re * cosPhase - inputSignal.im * sinPhase)
        let outIm = a * (inputSignal.re * sinPhase + inputSignal.im * cosPhase)

        return [outNode: OpticalSignal(re: outRe, im: outIm, wavelength: lambda)]
    }

    public func transferCoefficients() -> [OpticalTransferEntry] {
        guard let inNode = inputNode, let outNode = outputNode else { return [] }
        return [OpticalTransferEntry(inputNode: inNode, outputNode: outNode, coefficient: powerTransfer)]
    }
}
