/// MOSFET model parameters (Levels 1-3).
///
/// These parameters describe the electrical characteristics of an
/// MOS transistor for the Level 1-3 models used in both NMOS and
/// PMOS devices. Level 2 adds mobility degradation and DIBL, while
/// Level 3 introduces velocity saturation.
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

    /// Mobility degradation coefficient (1/V).
    public var theta: Double

    /// Drain-induced barrier lowering coefficient (V/V).
    public var eta: Double

    /// Velocity saturation coefficient (1/V).
    public var kappa: Double

    /// Saturation velocity (m/s).
    public var vmax: Double

    /// Gate oxide thickness (m).
    public var tox: Double

    /// Channel width (m).
    public var w: Double

    /// Channel length (m).
    public var l: Double

    // MARK: - Capacitance Parameters

    /// Gate-source overlap capacitance per unit width (F/m).
    public var cgso: Double

    /// Gate-drain overlap capacitance per unit width (F/m).
    public var cgdo: Double

    /// Gate-bulk overlap capacitance per unit length (F/m).
    public var cgbo: Double

    /// Zero-bias bulk junction bottom capacitance per unit area (F/m^2).
    public var cj: Double

    /// Zero-bias bulk junction sidewall capacitance per unit perimeter (F/m).
    public var cjsw: Double

    /// Bulk junction bottom grading coefficient.
    public var mj: Double

    /// Bulk junction sidewall grading coefficient.
    public var mjsw: Double

    /// Bulk junction potential (V).
    public var pb: Double

    /// Drain diffusion area (m^2).
    public var ad: Double

    /// Source diffusion area (m^2). Named `asrc` because `as` is a Swift keyword.
    public var asrc: Double

    /// Drain diffusion perimeter (m).
    public var pd: Double

    /// Source diffusion perimeter (m).
    public var ps: Double

    public init(
        vto: Double = 0.0,
        kp: Double = 2e-5,
        gamma: Double = 0.0,
        phi: Double = 0.6,
        lambda: Double = 0.0,
        theta: Double = 0.0,
        eta: Double = 0.0,
        kappa: Double = 0.0,
        vmax: Double = 0.0,
        tox: Double = 100e-9,
        w: Double = 10e-6,
        l: Double = 1e-6,
        cgso: Double = 0,
        cgdo: Double = 0,
        cgbo: Double = 0,
        cj: Double = 0,
        cjsw: Double = 0,
        mj: Double = 0.5,
        mjsw: Double = 0.33,
        pb: Double = 0.8,
        ad: Double = 0,
        asrc: Double = 0,
        pd: Double = 0,
        ps: Double = 0
    ) {
        self.vto = vto
        self.kp = kp
        self.gamma = gamma
        self.phi = phi
        self.lambda = lambda
        self.theta = theta
        self.eta = eta
        self.kappa = kappa
        self.vmax = vmax
        self.tox = tox
        self.w = w
        self.l = l
        self.cgso = cgso
        self.cgdo = cgdo
        self.cgbo = cgbo
        self.cj = cj
        self.cjsw = cjsw
        self.mj = mj
        self.mjsw = mjsw
        self.pb = pb
        self.ad = ad
        self.asrc = asrc
        self.pd = pd
        self.ps = ps
    }

    /// Effective transconductance parameter scaled by W/L.
    public var beta: Double {
        kp * w / l
    }

    /// Oxide capacitance per unit area (F/m^2): Cox = eps_ox / tox.
    public var cox: Double {
        guard tox > 0 else { return 0 }
        return 3.453e-11 / tox  // eps_ox = 3.9 * eps_0 = 3.9 * 8.854e-12
    }
}
