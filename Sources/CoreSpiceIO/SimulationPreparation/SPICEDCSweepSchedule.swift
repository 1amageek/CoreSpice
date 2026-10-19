/// Shared numeric DC coordinates for prepared and ordinary CLI execution.
public enum SPICEDCSweepSchedule {
    public enum Failure: Error, Sendable { case invalidDirection, pointLimit, nonAdvancingPoint }

    public static func values(from start: Double, through stop: Double, by step: Double,
                              maximumCount: Int, checkPoint: () throws -> Void = {}) throws -> [Double] {
        let span = stop - start
        guard start.isFinite, stop.isFinite, step.isFinite, step != 0, span.isFinite,
              (step > 0 ? stop >= start : stop <= start) else { throw Failure.invalidDirection }
        let quotient = span / step
        guard maximumCount > 0, quotient.isFinite, quotient >= 0, quotient < Double(maximumCount),
              var last = Int(exactly: quotient.rounded(.down)) else { throw Failure.pointLimit }
        let (next, overflow) = last.addingReportingOverflow(1)
        guard !overflow else { throw Failure.pointLimit }
        let candidate = start + Double(next) * step
        // Recover an integer interval lost by subtraction/division rounding, without a half-step overshoot.
        if candidate.isFinite, candidate != start,
           (step > 0 ? candidate <= stop.nextUp : candidate >= stop.nextDown) {
            last = next
        }
        guard last < maximumCount else { throw Failure.pointLimit }
        var values: [Double] = []; values.reserveCapacity(last + 1)
        for index in 0...last {
            try checkPoint()
            var value = start + Double(index) * step
            guard value.isFinite else { throw Failure.invalidDirection }
            if step > 0, value > stop {
                guard value == stop.nextUp else { throw Failure.invalidDirection }
                value = stop
            } else if step < 0, value < stop {
                guard value == stop.nextDown else { throw Failure.invalidDirection }
                value = stop
            }
            if let previous = values.last, (step > 0 ? value <= previous : value >= previous) {
                throw Failure.nonAdvancingPoint
            }
            if index == last, index > 0,
               value == (step > 0 ? stop.nextDown : stop.nextUp) {
                value = stop
            }
            values.append(value)
        }
        return values
    }
}
