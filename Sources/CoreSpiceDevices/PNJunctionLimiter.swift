import Foundation

/// SPICE3F5 DEVpnjlim algorithm for PN junction voltage limiting.
///
/// Prevents Newton-Raphson divergence caused by exponential nonlinearity
/// of PN junctions. When the voltage change between iterations is too large,
/// the new voltage is clamped using a logarithmic function that ensures
/// the diode current changes by at most a factor of ~e per iteration.
public enum PNJunctionLimiter {

    /// Limits a PN junction voltage change between NR iterations.
    ///
    /// - Parameters:
    ///   - vNew: The proposed junction voltage from the current NR iteration.
    ///   - vOld: The junction voltage from the previous NR iteration.
    ///   - vt: Thermal voltage (n * kT/q, including emission coefficient).
    ///   - isat: Saturation current of the junction.
    /// - Returns: The limited junction voltage.
    public static func limit(
        vNew: Double, vOld: Double,
        vt: Double, isat: Double
    ) -> Double {
        // Critical voltage above which the exponential grows rapidly
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))

        if vNew > vcrit && abs(vNew - vOld) > 2.0 * vt {
            // Large forward-bias step: use logarithmic limiting
            if vOld > 0 {
                let arg = 1.0 + (vNew - vOld) / vt
                if arg > 0 {
                    return vOld + vt * log(arg)
                } else {
                    return vcrit
                }
            } else {
                return vt * log(vNew / vt)
            }
        }

        return vNew
    }
}
