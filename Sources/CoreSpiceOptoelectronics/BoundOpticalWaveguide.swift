import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// An optical waveguide bound to optical input/output nodes.
///
/// Propagates an optical signal with:
/// - Attenuation: `10^(-loss_dB_per_cm * length_cm / 20)` (field amplitude)
/// - Phase shift: `exp(j * 2*pi*neff*length/lambda)` (complex rotation)
///
/// No electrical ports — this is a purely optical device.
///
/// **Limitations**:
/// - Group delay (`ng * L / c`) is not modeled in transient; propagation is instantaneous.
/// - No dispersion or nonlinear effects.
public struct BoundOpticalWaveguide: OpticalDevice, Sendable {

    public let instance: Instance

    private let inputNode: OpticalNode
    private let outputNode: OpticalNode

    /// Waveguide length in meters.
    private let length: Double

    /// Effective refractive index.
    private let neff: Double

    /// Group refractive index (reserved for future delay modeling).
    private let ng: Double

    /// Propagation loss in dB/cm.
    private let lossdBperCm: Double

    /// Pre-computed power transfer coefficient: `10^(-loss_dB_per_cm * length_cm / 10)`.
    private let powerTransfer: Double

    /// Pre-computed field amplitude transfer: `10^(-loss_dB_per_cm * length_cm / 20)`.
    private let fieldAmplitudeTransfer: Double

    public var opticalInputNodes: [OpticalNode] { [inputNode] }
    public var opticalOutputNodes: [OpticalNode] { [outputNode] }

    public init(
        instance: Instance,
        inputNode: OpticalNode,
        outputNode: OpticalNode,
        length: Double,
        neff: Double = 1.45,
        ng: Double = 1.5,
        lossdBperCm: Double = 0.5
    ) {
        self.instance = instance
        self.inputNode = inputNode
        self.outputNode = outputNode
        self.length = length
        self.neff = neff
        self.ng = ng
        self.lossdBperCm = lossdBperCm

        let lengthCm = length * 100.0  // m → cm
        self.powerTransfer = pow(10.0, -lossdBperCm * lengthCm / 10.0)
        self.fieldAmplitudeTransfer = pow(10.0, -lossdBperCm * lengthCm / 20.0)
    }

    // MARK: - OpticalDevice

    public func propagate(inputs: [OpticalNode: OpticalSignal]) -> [OpticalNode: OpticalSignal] {
        guard let inputSignal = inputs[inputNode] else {
            return [outputNode: .zero]
        }

        // Phase accumulated over the waveguide length
        let lambda = inputSignal.wavelength
        let phase = 2.0 * .pi * neff * length / lambda

        // Apply attenuation and phase rotation to complex field
        let cosPhase = cos(phase)
        let sinPhase = sin(phase)
        let a = fieldAmplitudeTransfer

        let outRe = a * (inputSignal.re * cosPhase - inputSignal.im * sinPhase)
        let outIm = a * (inputSignal.re * sinPhase + inputSignal.im * cosPhase)

        return [outputNode: OpticalSignal(re: outRe, im: outIm, wavelength: lambda)]
    }

    public func transferCoefficients() -> [OpticalTransferEntry] {
        // Power transfer coefficient for sensitivity propagation
        [OpticalTransferEntry(inputNode: inputNode, outputNode: outputNode, coefficient: powerTransfer)]
    }

    // MARK: - BoundDevice (no-op for purely optical device)

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {}
    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {}
    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {}

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
