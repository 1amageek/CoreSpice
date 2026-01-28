/// Level 1 MOSFET model parameters (Shichman-Hodges).
///
/// These parameters describe the electrical characteristics of an
/// MOS transistor for the Level 1 (square-law) model used in
/// both NMOS and PMOS devices.
public struct MOSFETModelParameters: Sendable {

    /// Threshold voltage (V).
    public var vto: Double

    /// Transconductance parameter (A/V^2).
    public var kp: Double

    /// Body-effect coefficient (V^0.5).
    public var gamma: Double

    /// Surface potential (V).
    public var phi: Double

    /// Channel-length modulation parameter (1/V).
    public var lambda: Double

    /// Gate oxide thickness (m).
    public var tox: Double

    /// Channel width (m).
    public var w: Double

    /// Channel length (m).
    public var l: Double

    public init(
        vto: Double = 0.7,
        kp: Double = 110e-6,
        gamma: Double = 0.4,
        phi: Double = 0.65,
        lambda: Double = 0.04,
        tox: Double = 100e-9,
        w: Double = 10e-6,
        l: Double = 1e-6
    ) {
        self.vto = vto
        self.kp = kp
        self.gamma = gamma
        self.phi = phi
        self.lambda = lambda
        self.tox = tox
        self.w = w
        self.l = l
    }

    /// Effective transconductance parameter scaled by W/L.
    public var beta: Double {
        kp * w / l
    }
}
