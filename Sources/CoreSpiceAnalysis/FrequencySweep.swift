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
    public func frequencies() -> [Double] {
        switch self {
        case .decade(let start, let stop, let ppd):
            var freqs: [Double] = []
            let decades = log10(stop / start)
            let totalPoints = Int(decades * Double(ppd))
            for i in 0...totalPoints {
                freqs.append(start * pow(10.0, Double(i) / Double(ppd)))
            }
            return freqs

        case .octave(let start, let stop, let ppo):
            var freqs: [Double] = []
            let octaves = log2(stop / start)
            let totalPoints = Int(octaves * Double(ppo))
            for i in 0...totalPoints {
                freqs.append(start * pow(2.0, Double(i) / Double(ppo)))
            }
            return freqs

        case .linear(let start, let stop, let points):
            guard points > 1 else { return [start] }
            return (0..<points).map {
                start + Double($0) * (stop - start) / Double(points - 1)
            }

        case .single(let f):
            return [f]
        }
    }
}
