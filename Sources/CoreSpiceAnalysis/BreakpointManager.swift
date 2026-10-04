/// Manages waveform discontinuity breakpoints for transient analysis.
///
/// During time-domain simulation the integration engine must land on
/// or very near waveform transition times (rising/falling edges of
/// pulse sources, PWL segment boundaries, etc.). The breakpoint
/// manager constrains the proposed timestep so that it does not
/// overshoot the next breakpoint.
public struct BreakpointManager: Sendable {

    /// Sorted array of breakpoint times (deduplicated).
    private var breakpoints: [Double] = []

    /// Index of the next unprocessed breakpoint.
    private var currentIndex: Int = 0

    public init() {}

    /// Adds breakpoints to the schedule, merging and deduplicating.
    ///
    /// - Parameter points: An array of simulation times at which
    ///   waveform discontinuities occur.
    public mutating func addBreakpoints(_ points: [Double]) {
        breakpoints.append(contentsOf: points)
        breakpoints.sort()
        // Remove near-duplicates
        breakpoints = breakpoints.reduce(into: []) { result, point in
            if result.last.map({ $0 != point }) ?? true {
                result.append(point)
            }
        }
    }

    /// Constrains a proposed timestep so that it does not overshoot the
    /// next breakpoint.
    ///
    /// - Parameters:
    ///   - currentTime: The current simulation time.
    ///   - proposedStep: The timestep proposed by the adaptive controller.
    /// - Returns: The constrained timestep, which may be shorter than
    ///   `proposedStep` if a breakpoint is nearby.
    public mutating func constrainTimeStep(
        currentTime: Double,
        proposedStep: Double
    ) -> Double {
        // Advance past breakpoints that are at or before the current time
        while currentIndex < breakpoints.count &&
              breakpoints[currentIndex] <= currentTime {
            currentIndex += 1
        }

        guard currentIndex < breakpoints.count else { return proposedStep }

        let nextBP = breakpoints[currentIndex]
        let distToBP = nextBP - currentTime

        if distToBP <= proposedStep { return distToBP }
        // Divide the final approach into two representable steps instead of leaving
        // a rounding-sized remainder after a full step. Neither step exceeds the proposal.
        if distToBP / proposedStep < 2 { return distToBP / 2 }
        return proposedStep
    }

    /// Checks whether the given time coincides with a waveform breakpoint.
    ///
    /// - Parameters:
    ///   - time: The simulation time to check.
    ///   - tolerance: Match tolerance in seconds (default 1e-12).
    /// - Returns: `true` if `time` is within `tolerance` of any breakpoint.
    public func isAtBreakpoint(_ time: Double, tolerance: Double = 0) -> Bool {
        // Binary search for nearest breakpoint
        var lo = 0
        var hi = breakpoints.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if breakpoints[mid] < time - tolerance {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < breakpoints.count && abs(breakpoints[lo] - time) <= tolerance {
            return true
        }
        if lo > 0 && abs(breakpoints[lo - 1] - time) <= tolerance {
            return true
        }
        return false
    }
}
