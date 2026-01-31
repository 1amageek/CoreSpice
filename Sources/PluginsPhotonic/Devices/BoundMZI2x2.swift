import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// A bound 2x2 MZI device ready for SPICE-level simulation.
///
/// In DC and transient modes the MZI acts as a pass-through
/// (photonic devices do not contribute to electrical MNA).
/// In AC mode the complex transfer matrix can be stamped to
/// model interference effects at a linearised operating point.
///
/// Also conforms to `OpticalDevice` for optical DAG propagation
/// in mixed-signal optoelectronic simulations.
///
/// ## Transfer Matrix
/// ```
/// [E_out0]   [cos(θ/2)·e^(iφ)   -sin(θ/2)     ] [E_in0]
/// [E_out1] = [sin(θ/2)·e^(iφ)    cos(θ/2)      ] [E_in1]
/// ```
/// with field amplitude scaled by `√(1-loss)`.
public struct BoundMZI2x2: OpticalDevice, Sendable {

    public let instance: Instance

    /// Internal phase shift in radians.
    public let theta: Double

    /// External phase in radians.
    public let phi: Double

    /// Insertion loss (linear, 0--1).
    public let loss: Double

    /// Optical input nodes (nil when used in GPU mesh path only).
    private let inputNode0: OpticalNode?
    private let inputNode1: OpticalNode?

    /// Optical output nodes (nil when used in GPU mesh path only).
    private let outputNode0: OpticalNode?
    private let outputNode1: OpticalNode?

    public var opticalInputNodes: [OpticalNode] {
        [inputNode0, inputNode1].compactMap { $0 }
    }

    public var opticalOutputNodes: [OpticalNode] {
        [outputNode0, outputNode1].compactMap { $0 }
    }

    public init(
        instance: Instance,
        theta: Double,
        phi: Double,
        loss: Double,
        inputNode0: OpticalNode? = nil,
        inputNode1: OpticalNode? = nil,
        outputNode0: OpticalNode? = nil,
        outputNode1: OpticalNode? = nil
    ) {
        self.instance = instance
        self.theta = theta
        self.phi = phi
        self.loss = loss
        self.inputNode0 = inputNode0
        self.inputNode1 = inputNode1
        self.outputNode0 = outputNode0
        self.outputNode1 = outputNode1
    }

    // MARK: - OpticalDevice

    public func propagate(inputs: [OpticalNode: OpticalSignal]) -> [OpticalNode: OpticalSignal] {
        guard let in0 = inputNode0, let in1 = inputNode1,
              let out0 = outputNode0, let out1 = outputNode1 else {
            return [:]
        }

        let sig0 = inputs[in0] ?? .zero
        let sig1 = inputs[in1] ?? .zero

        // Transfer matrix elements (field amplitude)
        let a = (1.0 - loss).squareRoot()
        let cosHalf = cos(theta / 2.0)
        let sinHalf = sin(theta / 2.0)
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // t11 = a * cos(θ/2) * exp(iφ)
        let t11Re = a * cosHalf * cosPhi
        let t11Im = a * cosHalf * sinPhi
        // t12 = -a * sin(θ/2)
        let t12 = -a * sinHalf
        // t21 = a * sin(θ/2) * exp(iφ)
        let t21Re = a * sinHalf * cosPhi
        let t21Im = a * sinHalf * sinPhi
        // t22 = a * cos(θ/2)
        let t22 = a * cosHalf

        // E_out0 = t11 * E_in0 + t12 * E_in1
        let out0Re = (t11Re * sig0.re - t11Im * sig0.im) + t12 * sig1.re
        let out0Im = (t11Re * sig0.im + t11Im * sig0.re) + t12 * sig1.im

        // E_out1 = t21 * E_in0 + t22 * E_in1
        let out1Re = (t21Re * sig0.re - t21Im * sig0.im) + t22 * sig1.re
        let out1Im = (t21Re * sig0.im + t21Im * sig0.re) + t22 * sig1.im

        let lambda = sig0.wavelength > 0 ? sig0.wavelength : sig1.wavelength

        return [
            out0: OpticalSignal(re: out0Re, im: out0Im, wavelength: lambda),
            out1: OpticalSignal(re: out1Re, im: out1Im, wavelength: lambda)
        ]
    }

    public func transferCoefficients() -> [OpticalTransferEntry] {
        guard let in0 = inputNode0, let in1 = inputNode1,
              let out0 = outputNode0, let out1 = outputNode1 else {
            return []
        }

        let throughput = 1.0 - loss
        let cosHalfSq = cos(theta / 2.0) * cos(theta / 2.0)
        let sinHalfSq = sin(theta / 2.0) * sin(theta / 2.0)

        return [
            OpticalTransferEntry(inputNode: in0, outputNode: out0, coefficient: throughput * cosHalfSq),
            OpticalTransferEntry(inputNode: in1, outputNode: out0, coefficient: throughput * sinHalfSq),
            OpticalTransferEntry(inputNode: in0, outputNode: out1, coefficient: throughput * sinHalfSq),
            OpticalTransferEntry(inputNode: in1, outputNode: out1, coefficient: throughput * cosHalfSq)
        ]
    }
}
