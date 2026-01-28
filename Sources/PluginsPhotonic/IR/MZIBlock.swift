/// Parameters for a single Mach-Zehnder Interferometer (MZI) unit.
///
/// An MZI block defines the phase shift, external phase, and
/// insertion loss of a 2x2 coupler element in the photonic mesh.
public struct MZIBlock: Sendable {

    /// Internal phase shift in radians.
    public let theta: Double

    /// External phase in radians.
    public let phi: Double

    /// Insertion loss as a linear factor (0--1, where 1 means no loss).
    public let loss: Double

    public init(theta: Double, phi: Double = 0, loss: Double = 1.0) {
        self.theta = theta
        self.phi = phi
        self.loss = loss
    }

    /// Identity MZI: no phase shift, no external phase, no loss.
    public static let identity = MZIBlock(theta: 0, phi: 0, loss: 1.0)

    /// Balanced 50/50 beam splitter (pi/2 internal phase).
    public static let halfSplitter = MZIBlock(theta: .pi / 2, phi: 0, loss: 1.0)
}
