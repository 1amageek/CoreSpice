import SharedTypes
import Foundation

/// Converts MZI block parameters into GPU-ready transfer-matrix coefficients.
///
/// The generator applies wavelength-dependent phase corrections
/// using the provided `WavelengthModel` before computing the
/// complex 2x2 transfer matrix for each MZI element.
public struct CoefficientGenerator: Sendable {

    /// The wavelength model used for phase correction.
    public let wavelengthModel: WavelengthModel

    public init(wavelengthModel: WavelengthModel = WavelengthModel()) {
        self.wavelengthModel = wavelengthModel
    }

    /// Generate coefficients for a single MZI block at a given wavelength.
    ///
    /// The 2x2 MZI transfer matrix is:
    /// ```
    /// T = loss * | cos(theta/2) * e^(i*phi)    i * sin(theta/2)          |
    ///            | i * sin(theta/2)             cos(theta/2) * e^(-i*phi) |
    /// ```
    ///
    /// - Parameters:
    ///   - block: MZI block parameters (theta, phi, loss).
    ///   - wavelength: Operating wavelength in meters.
    /// - Returns: The computed transfer-matrix coefficients.
    public func generate(block: MZIBlock, wavelength: Double) -> MZICoefficients {
        let effectiveTheta = wavelengthModel.effectivePhase(
            basePhase: block.theta, wavelength: wavelength)
        let loss = Float(block.loss)
        let cosT = Float(cos(effectiveTheta / 2))
        let sinT = Float(sin(effectiveTheta / 2))
        let cosPhi = Float(cos(block.phi))
        let sinPhi = Float(sin(block.phi))

        // m00 = loss * cos(theta/2) * e^(i*phi)
        // m01 = loss * i * sin(theta/2) * e^(i*phi)
        //      = loss * sin(theta/2) * (i*cosφ - sinφ) = loss * sinT * (-sinφ + i*cosφ)
        // m10 = loss * i * sin(theta/2) * e^(-i*phi)
        //      = loss * sin(theta/2) * (i*cosφ + sinφ) = loss * sinT * (sinφ + i*cosφ)
        // m11 = loss * cos(theta/2) * e^(-i*phi)
        return MZICoefficients(
            m00_real: loss * cosT * cosPhi,
            m00_imag: loss * cosT * sinPhi,
            m01_real: loss * sinT * (-sinPhi),
            m01_imag: loss * sinT * cosPhi,
            m10_real: loss * sinT * sinPhi,
            m10_imag: loss * sinT * cosPhi,
            m11_real: loss * cosT * cosPhi,
            m11_imag: -loss * cosT * sinPhi
        )
    }

    /// Generate coefficients for all MZI blocks in a layer.
    ///
    /// - Parameters:
    ///   - layer: The mesh layer whose blocks are to be compiled.
    ///   - wavelength: Operating wavelength in meters.
    /// - Returns: Array of coefficients, one per pair.
    public func generateLayer(layer: MeshLayer, wavelength: Double) -> [MZICoefficients] {
        layer.blocks.map { generate(block: $0, wavelength: wavelength) }
    }
}
