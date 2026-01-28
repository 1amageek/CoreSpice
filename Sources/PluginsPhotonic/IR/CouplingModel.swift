import Foundation

/// Model for a directional coupler's coupling coefficient.
///
/// The coupling coefficient `kappa` determines the power split ratio
/// of the coupler. A value of 0.5 corresponds to a 3 dB (50/50) coupler.
public struct CouplingModel: Sendable {

    /// Coupling coefficient in the range [0, 1].
    /// 0.5 produces a balanced 3 dB coupler.
    public let kappa: Double

    public init(kappa: Double = 0.5) {
        self.kappa = kappa
    }

    /// The coupler transfer-matrix angle derived from the coupling coefficient.
    ///
    /// This is the angle whose sine-squared equals `kappa`,
    /// suitable for constructing the 2x2 unitary coupling matrix.
    public var couplerAngle: Double { asin(sqrt(kappa)) }
}
