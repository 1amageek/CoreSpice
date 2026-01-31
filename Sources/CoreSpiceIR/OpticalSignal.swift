import Foundation

/// An optical signal represented as a complex electric field amplitude.
///
/// Uses `re`/`im` (real/imaginary) as the primary representation rather
/// than amplitude/phase because:
/// - Zero-amplitude signals have well-defined representation (no phase singularity)
/// - Interference and combining operations are linear (addition of complex fields)
/// - Compatible with GPU compute (Complex<Double> = 2 x Double)
///
/// The field amplitude is in units of √W, so `power = re² + im²` gives
/// the optical power in watts.
public struct OpticalSignal: Sendable, Equatable {

    /// Real part of the electric field amplitude [√W].
    public var re: Double

    /// Imaginary part of the electric field amplitude [√W].
    public var im: Double

    /// Wavelength in meters (default 1550 nm for telecom C-band).
    public var wavelength: Double

    /// Optical power in watts: |E|² = re² + im².
    public var power: Double { re * re + im * im }

    /// Field amplitude in √W.
    public var amplitude: Double { power.squareRoot() }

    /// Phase angle in radians.
    public var phase: Double { atan2(im, re) }

    public init(re: Double, im: Double, wavelength: Double = 1550e-9) {
        self.re = re
        self.im = im
        self.wavelength = wavelength
    }

    /// Creates a signal from polar representation (amplitude and phase).
    public static func fromPolar(
        amplitude: Double,
        phase: Double,
        wavelength: Double = 1550e-9
    ) -> OpticalSignal {
        OpticalSignal(
            re: amplitude * cos(phase),
            im: amplitude * sin(phase),
            wavelength: wavelength
        )
    }

    /// Zero optical signal (no light).
    public static let zero = OpticalSignal(re: 0, im: 0, wavelength: 1550e-9)

    /// Linear combination (coherent combining / interference).
    public static func + (lhs: OpticalSignal, rhs: OpticalSignal) -> OpticalSignal {
        OpticalSignal(re: lhs.re + rhs.re, im: lhs.im + rhs.im, wavelength: lhs.wavelength)
    }

    /// Scalar multiplication (attenuation / gain).
    public static func * (scalar: Double, signal: OpticalSignal) -> OpticalSignal {
        OpticalSignal(re: scalar * signal.re, im: scalar * signal.im, wavelength: signal.wavelength)
    }

    /// Scalar multiplication (attenuation / gain), reversed operand order.
    public static func * (signal: OpticalSignal, scalar: Double) -> OpticalSignal {
        scalar * signal
    }
}
