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
            if result.last.map({ abs($0 - point) > 1e-15 }) ?? true {
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
              breakpoints[currentIndex] <= currentTime + 1e-15 {
            currentIndex += 1
        }

        guard currentIndex < breakpoints.count else { return proposedStep }

        let nextBP = breakpoints[currentIndex]
        let distToBP = nextBP - currentTime

        // If the breakpoint is within 110% of the proposed step, land on it
        if distToBP < proposedStep * 1.1 {
            return distToBP
        }

        return proposedStep
    }
}
