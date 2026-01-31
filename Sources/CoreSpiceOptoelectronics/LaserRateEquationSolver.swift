import Foundation

/// Implicit solver for laser diode rate equations.
///
/// Solves the coupled carrier density (N) and photon density (S) equations:
/// ```
/// dN/dt = I(t)/(q*V_act) - N/τ_N - G(N)*S
/// dS/dt = Γ*G(N)*S - S/τ_P + β_sp*N/τ_N
/// ```
/// where `G(N) = g0 * (N - N_tr)` is the linear gain (g0 in m³/s).
///
/// The solver uses the same integration method (Backward Euler or Trapezoidal)
/// as the outer transient loop, with a local 2×2 Newton iteration on
/// unnormalized variables (N, S), scaling residuals for conditioning.
public struct LaserRateEquationSolver: Sendable {

    /// Maximum local Newton iterations.
    private static let maxIterations = 50

    /// Convergence tolerance (relative).
    private static let tolerance = 1e-10

    /// Minimum photon density floor to avoid singularity.
    private static let sFloor = 1e-10

    /// State of the rate equation solver.
    public struct State: Sendable {
        /// Carrier density (1/m³).
        public var carrierDensity: Double

        /// Photon density (1/m³).
        public var photonDensity: Double

        public init(carrierDensity: Double = 0, photonDensity: Double = 0) {
            self.carrierDensity = carrierDensity
            self.photonDensity = photonDensity
        }
    }

    /// Integration method matching the outer transient loop.
    public enum IntegrationMethod: Sendable {
        case backwardEuler
        case trapezoidal
    }

    /// Computes the gain rate G(N) = g0 * (N - N_tr).
    @inline(__always)
    private static func gainRate(N: Double, g0: Double, nTr: Double) -> Double {
        g0 * (N - nTr)
    }

    /// Computes dN/dt and dS/dt at a given (N, S, I) operating point.
    private static func derivatives(
        N: Double, S: Double, current: Double,
        params: LaserDiodeModelParameters
    ) -> (dNdt: Double, dSdt: Double) {
        let q = 1.602176634e-19
        let J = current / (q * params.activeVolume)
        let G = gainRate(N: N, g0: params.differentialGain, nTr: params.transparencyCarrierDensity)

        let dNdt = J - N / params.carrierLifetime - G * S
        let dSdt = params.confinementFactor * G * S - S / params.photonLifetime
                   + params.spontaneousEmissionFactor * N / params.carrierLifetime
        return (dNdt, dSdt)
    }

    /// Solves the rate equations for one time step.
    ///
    /// - Parameters:
    ///   - current: Diode forward current I(t) at the new time point.
    ///   - previous: State at the previous time point (N_{n-1}, S_{n-1}).
    ///   - previousDerivatives: (dN/dt, dS/dt) at the previous time point (for trapezoidal).
    ///   - dt: Time step size (s).
    ///   - params: Laser diode model parameters.
    ///   - method: Integration method.
    /// - Returns: Updated state and derivatives at the new time point.
    public static func solve(
        current: Double,
        previous: State,
        previousDerivatives: (dNdt: Double, dSdt: Double)?,
        dt: Double,
        params: LaserDiodeModelParameters,
        method: IntegrationMethod
    ) -> (state: State, derivatives: (dNdt: Double, dSdt: Double)) {
        let q = 1.602176634e-19
        let vAct = params.activeVolume
        let tauN = params.carrierLifetime
        let tauP = params.photonLifetime
        let g0 = params.differentialGain
        let nTr = params.transparencyCarrierDensity
        let gamma = params.confinementFactor
        let betaSp = params.spontaneousEmissionFactor

        let J = current / (q * vAct)  // Injection rate (1/m³/s)

        // Scaling references for conditioning
        let nScale = max(nTr, 1.0)
        let sScale = max(previous.photonDensity, 1.0 / (g0 * nTr * tauP))

        // Initial guess from previous state
        var N = max(previous.carrierDensity, 0)
        var S = max(previous.photonDensity, sFloor)

        // Integration coefficients
        let c0: Double  // coefficient for (x_new - x_prev)/dt term
        switch method {
        case .backwardEuler:
            // (N - N_prev)/dt = f(N, S)  →  N/dt - f(N, S) = N_prev/dt
            for _ in 0..<maxIterations {
                let G = gainRate(N: N, g0: g0, nTr: nTr)

                // Residuals: x/dt - f(x) - x_prev/dt = 0
                let f1 = N / dt - (J - N / tauN - G * S) - previous.carrierDensity / dt
                let f2 = S / dt - (gamma * G * S - S / tauP + betaSp * N / tauN) - previous.photonDensity / dt

                // Jacobian df/dN, df/dS
                // df1/dN = 1/dt + 1/tauN + g0*S
                let j11 = 1.0 / dt + 1.0 / tauN + g0 * S
                // df1/dS = G = g0*(N - nTr)
                let j12 = G
                // df2/dN = -gamma*g0*S - betaSp/tauN
                let j21 = -gamma * g0 * S - betaSp / tauN
                // df2/dS = 1/dt - gamma*G + 1/tauP
                let j22 = 1.0 / dt - gamma * G + 1.0 / tauP

                let det = j11 * j22 - j12 * j21
                guard abs(det) > 1e-50 else { break }

                let dN = -(j22 * f1 - j12 * f2) / det
                let dS = -(-j21 * f1 + j11 * f2) / det

                N += dN
                S += dS
                N = max(N, 0)
                S = max(S, sFloor)

                if abs(dN) / max(abs(N), nScale) < tolerance
                    && abs(dS) / max(abs(S), sScale) < tolerance {
                    break
                }
            }

        case .trapezoidal:
            // (N - N_prev)/(dt/2) = f(N,S) + f_prev  →
            // 2*N/dt - f(N,S) = 2*N_prev/dt + f_prev
            c0 = 2.0 / dt
            let prevDN = previousDerivatives?.dNdt ?? 0
            let prevDS = previousDerivatives?.dSdt ?? 0

            for _ in 0..<maxIterations {
                let G = gainRate(N: N, g0: g0, nTr: nTr)

                let fN = J - N / tauN - G * S
                let fS = gamma * G * S - S / tauP + betaSp * N / tauN

                let f1 = c0 * N - fN - c0 * previous.carrierDensity - prevDN
                let f2 = c0 * S - fS - c0 * previous.photonDensity - prevDS

                let j11 = c0 + 1.0 / tauN + g0 * S
                let j12 = G
                let j21 = -gamma * g0 * S - betaSp / tauN
                let j22 = c0 - gamma * G + 1.0 / tauP

                let det = j11 * j22 - j12 * j21
                guard abs(det) > 1e-50 else { break }

                let dN = -(j22 * f1 - j12 * f2) / det
                let dS = -(-j21 * f1 + j11 * f2) / det

                N += dN
                S += dS
                N = max(N, 0)
                S = max(S, sFloor)

                if abs(dN) / max(abs(N), nScale) < tolerance
                    && abs(dS) / max(abs(S), sScale) < tolerance {
                    break
                }
            }
        }

        let derivs = derivatives(N: N, S: S, current: current, params: params)

        return (
            state: State(carrierDensity: N, photonDensity: S),
            derivatives: derivs
        )
    }

    /// Computes the optical output power from photon density.
    ///
    /// `P = h*ν * V_act * S / τ_P` (photon energy × emission rate from cavity).
    public static func opticalPower(
        photonDensity: Double,
        params: LaserDiodeModelParameters
    ) -> Double {
        let h = 6.62607015e-34
        let c = 299792458.0
        let photonEnergy = h * c / params.wavelength
        return photonEnergy * params.activeVolume * photonDensity / params.photonLifetime
    }

    /// Computes the DC steady-state for the rate equations at a given current.
    ///
    /// Used to initialize the transient simulation from the DC operating point.
    ///
    /// At steady state with G(N) = g0*(N - N_tr):
    /// - Threshold: `Γ * g0 * (N_th - N_tr) = 1/τ_P`
    ///   → `N_th = N_tr + 1/(Γ * g0 * τ_P)`
    /// - Below threshold: `N ≈ J * τ_N`, `S ≈ 0`
    /// - Above threshold: `N ≈ N_th`, `S = (J - N_th/τ_N) / G(N_th)`
    public static func dcSteadyState(
        current: Double,
        params: LaserDiodeModelParameters
    ) -> State {
        let q = 1.602176634e-19
        let vAct = params.activeVolume
        let tauN = params.carrierLifetime
        let tauP = params.photonLifetime
        let g0 = params.differentialGain
        let nTr = params.transparencyCarrierDensity
        let gamma = params.confinementFactor
        let betaSp = params.spontaneousEmissionFactor

        let J = current / (q * vAct)  // Injection rate (1/m³/s)

        // Threshold carrier density: Γ * g0 * (N_th - N_tr) = 1/τ_P
        let nTh = nTr + 1.0 / (gamma * g0 * tauP)

        // Threshold injection rate
        let jTh = nTh / tauN

        if J < jTh {
            // Below threshold
            let N = J * tauN
            let G = g0 * max(N - nTr, 0)
            let denom = 1.0 / tauP - gamma * G
            let S: Double
            if denom > 0 {
                S = betaSp * N / (tauN * denom)
            } else {
                // Near threshold, use small value
                S = sFloor
            }
            return State(carrierDensity: max(N, 0), photonDensity: max(S, sFloor))
        } else {
            // Above threshold: N clamped near N_th, S from power balance
            let N = nTh
            let G = g0 * (N - nTr)  // = 1/(Γ*τ_P)
            let S = (J - N / tauN) / G
            return State(carrierDensity: N, photonDensity: max(S, sFloor))
        }
    }

    /// Computes the small-signal relaxation oscillation frequency and damping.
    ///
    /// Used for AC analysis to construct the laser transfer function:
    /// `H(ω) = ω_r² / (ω_r² - ω² + jω*γ_d)`
    ///
    /// `ω_r² = Γ * g0 * S₀ / τ_P` (from linearizing rate equations)
    /// `γ_d = 1/τ_N + g0 * S₀`
    public static func smallSignalParameters(
        steadyState: State,
        params: LaserDiodeModelParameters
    ) -> (omegaR: Double, gammaDamping: Double) {
        let g0 = params.differentialGain
        let tauN = params.carrierLifetime
        let tauP = params.photonLifetime
        let gamma = params.confinementFactor

        let S0 = steadyState.photonDensity

        // ω_r² = Γ * g0 * S₀ / τ_P
        let omegaRsq = gamma * g0 * S0 / tauP
        let omegaR = omegaRsq > 0 ? omegaRsq.squareRoot() : 0

        // γ_d = 1/τ_N + g0 * S₀
        let gammaDamping = 1.0 / tauN + g0 * S0

        return (omegaR: omegaR, gammaDamping: gammaDamping)
    }
}
