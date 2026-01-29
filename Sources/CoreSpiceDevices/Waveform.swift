import Foundation

/// A time-value pair for piecewise-linear waveforms.
public struct PWLPoint: Sendable {
    public let time: Double
    public let value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// Time-varying source waveforms for transient analysis.
public enum Waveform: Sendable {
    /// Constant DC value.
    case dc(Double)

    /// Periodic pulse waveform.
    case pulse(v1: Double, v2: Double, delay: Double, rise: Double, fall: Double, width: Double, period: Double)

    /// Sinusoidal waveform.
    case sine(offset: Double, amplitude: Double, frequency: Double, delay: Double, phase: Double)

    /// Piecewise-linear waveform.
    case pwl(points: [PWLPoint])

    /// The DC operating point value (value at time 0).
    ///
    /// For DC analysis, this is the effective source value.
    public var dcValue: Double {
        value(at: 0.0)
    }

    /// Evaluate the waveform at the given time.
    public func value(at time: Double) -> Double {
        switch self {
        case .dc(let v):
            return v

        case .pulse(let v1, let v2, let delay, let rise, let fall, let width, let period):
            return Self.evaluatePulse(
                time: time, v1: v1, v2: v2, delay: delay,
                rise: rise, fall: fall, width: width, period: period
            )

        case .sine(let offset, let amplitude, let frequency, let delay, let phase):
            return Self.evaluateSine(
                time: time, offset: offset, amplitude: amplitude,
                frequency: frequency, delay: delay, phase: phase
            )

        case .pwl(let points):
            return Self.evaluatePWL(time: time, points: points)
        }
    }

    /// Return discontinuity times within the given interval.
    ///
    /// The breakpoint manager uses these to place integration steps
    /// precisely at waveform transitions.
    public func breakpoints(in interval: ClosedRange<Double>) -> [Double] {
        switch self {
        case .dc:
            return []

        case .pulse(_, _, let delay, let rise, let fall, let width, let period):
            var result: [Double] = []
            guard period > 0 else { return [] }
            var cycleStart = delay
            while cycleStart <= interval.upperBound {
                let edges = [
                    cycleStart,
                    cycleStart + rise,
                    cycleStart + rise + width,
                    cycleStart + rise + width + fall,
                ]
                for edge in edges {
                    if interval.contains(edge) {
                        result.append(edge)
                    }
                }
                cycleStart += period
            }
            return result

        case .sine:
            // Sinusoids are smooth; no breakpoints needed.
            return []

        case .pwl(let points):
            return points
                .map(\.time)
                .filter { interval.contains($0) }
        }
    }

    // MARK: - Private Evaluation Helpers

    private static func evaluatePulse(
        time: Double, v1: Double, v2: Double, delay: Double,
        rise: Double, fall: Double, width: Double, period: Double
    ) -> Double {
        guard time >= delay else { return v1 }
        guard period > 0 else { return v1 }

        let t = (time - delay).truncatingRemainder(dividingBy: period)
        if t < rise {
            // Rising edge
            let fraction = rise > 0 ? t / rise : 1.0
            return v1 + (v2 - v1) * fraction
        } else if t < rise + width {
            // Pulse high
            return v2
        } else if t < rise + width + fall {
            // Falling edge
            let fraction = fall > 0 ? (t - rise - width) / fall : 1.0
            return v2 + (v1 - v2) * fraction
        } else {
            // Pulse low
            return v1
        }
    }

    private static func evaluateSine(
        time: Double, offset: Double, amplitude: Double,
        frequency: Double, delay: Double, phase: Double
    ) -> Double {
        guard time >= delay else { return offset }
        let t = time - delay
        let phaseRadians = phase * .pi / 180.0
        return offset + amplitude * sin(2.0 * .pi * frequency * t + phaseRadians)
    }

    private static func evaluatePWL(time: Double, points: [PWLPoint]) -> Double {
        guard !points.isEmpty else { return 0.0 }
        guard points.count > 1 else { return points[0].value }

        if time <= points[0].time {
            return points[0].value
        }
        if time >= points[points.count - 1].time {
            return points[points.count - 1].value
        }

        for i in 1..<points.count {
            if time <= points[i].time {
                let t0 = points[i - 1].time
                let t1 = points[i].time
                let v0 = points[i - 1].value
                let v1 = points[i].value
                let dt = t1 - t0
                guard dt > 0 else { return v0 }
                let fraction = (time - t0) / dt
                return v0 + (v1 - v0) * fraction
            }
        }

        return points[points.count - 1].value
    }
}
