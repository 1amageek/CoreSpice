import Foundation

/// Defines the frequency points for an AC small-signal analysis.
///
/// Four sweep modes are supported:
/// - ``decade``: Logarithmically spaced points across one or more decades (factor of 10).
/// - ``octave``: Logarithmically spaced points across octaves (factor of 2).
/// - ``linear``: Linearly spaced points between start and stop frequencies.
/// - ``single``: A single frequency point.
public enum FrequencySweep: Sendable {

    /// Logarithmic sweep with a fixed number of points per decade.
    case decade(start: Double, stop: Double, pointsPerDecade: Int)

    /// Logarithmic sweep with a fixed number of points per octave.
    case octave(start: Double, stop: Double, pointsPerOctave: Int)

    /// Linear sweep with evenly spaced points.
    case linear(start: Double, stop: Double, points: Int)

    /// A single frequency point.
    case single(Double)

    /// Generates the array of frequency values for this sweep.
    public func frequencies() throws -> [Double] {
        switch self {
        case .decade(let start, let stop, let ppd):
            try validateLogSweep(
                start: start,
                stop: stop,
                pointsPerInterval: ppd,
                intervalName: "pointsPerDecade"
            )
            var freqs: [Double] = []
            let decades = log10(stop / start)
            let totalPointEstimate = decades * Double(ppd)
            try validateGeneratedPointEstimate(totalPointEstimate + 1)
            let totalPoints = Int(totalPointEstimate)
            for i in 0...totalPoints {
                freqs.append(start * pow(10.0, Double(i) / Double(ppd)))
            }
            return freqs

        case .octave(let start, let stop, let ppo):
            try validateLogSweep(
                start: start,
                stop: stop,
                pointsPerInterval: ppo,
                intervalName: "pointsPerOctave"
            )
            var freqs: [Double] = []
            let octaves = log2(stop / start)
            let totalPointEstimate = octaves * Double(ppo)
            try validateGeneratedPointEstimate(totalPointEstimate + 1)
            let totalPoints = Int(totalPointEstimate)
            for i in 0...totalPoints {
                freqs.append(start * pow(2.0, Double(i) / Double(ppo)))
            }
            return freqs

        case .linear(let start, let stop, let points):
            try validateLinearSweep(start: start, stop: stop, points: points)
            guard points > 1 else { return [start] }
            try validateGeneratedPointCount(points)
            return (0..<points).map {
                start + Double($0) * (stop - start) / Double(points - 1)
            }

        case .single(let f):
            try validateFiniteFrequency(f, name: "frequency", allowZero: true)
            return [f]
        }
    }

    private func validateLogSweep(
        start: Double,
        stop: Double,
        pointsPerInterval: Int,
        intervalName: String
    ) throws {
        try validateFiniteFrequency(start, name: "start frequency", allowZero: false)
        try validateFiniteFrequency(stop, name: "stop frequency", allowZero: false)
        guard stop >= start else {
            throw AnalysisError.invalidConfiguration("stop frequency must be greater than or equal to start frequency")
        }
        guard pointsPerInterval > 0 else {
            throw AnalysisError.invalidConfiguration("\(intervalName) must be positive")
        }
    }

    private func validateLinearSweep(start: Double, stop: Double, points: Int) throws {
        try validateFiniteFrequency(start, name: "start frequency", allowZero: true)
        try validateFiniteFrequency(stop, name: "stop frequency", allowZero: true)
        guard stop >= start else {
            throw AnalysisError.invalidConfiguration("stop frequency must be greater than or equal to start frequency")
        }
        guard points > 0 else {
            throw AnalysisError.invalidConfiguration("linear sweep point count must be positive")
        }
    }

    private func validateFiniteFrequency(
        _ value: Double,
        name: String,
        allowZero: Bool
    ) throws {
        guard value.isFinite else {
            throw AnalysisError.invalidConfiguration("\(name) must be finite")
        }
        if allowZero {
            guard value >= 0 else {
                throw AnalysisError.invalidConfiguration("\(name) must be nonnegative")
            }
        } else {
            guard value > 0 else {
                throw AnalysisError.invalidConfiguration("\(name) must be positive")
            }
        }
    }

    private func validateGeneratedPointCount(_ count: Int) throws {
        let maximumGeneratedPointCount = 1_000_000
        guard count > 0 else {
            throw AnalysisError.invalidConfiguration("frequency sweep must generate at least one point")
        }
        guard count <= maximumGeneratedPointCount else {
            throw AnalysisError.invalidConfiguration("frequency sweep point count exceeds \(maximumGeneratedPointCount)")
        }
    }

    private func validateGeneratedPointEstimate(_ count: Double) throws {
        let maximumGeneratedPointCount = 1_000_000
        guard count.isFinite, count > 0 else {
            throw AnalysisError.invalidConfiguration("frequency sweep must generate at least one finite point")
        }
        guard count <= Double(maximumGeneratedPointCount) else {
            throw AnalysisError.invalidConfiguration("frequency sweep point count exceeds \(maximumGeneratedPointCount)")
        }
    }
}
