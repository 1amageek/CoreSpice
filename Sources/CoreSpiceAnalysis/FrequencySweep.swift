import Foundation

/// Defines the frequency points for an AC small-signal analysis.
///
/// Three sweep modes are supported:
/// - ``decade``: Logarithmically spaced points across one or more decades.
/// - ``linear``: Linearly spaced points between start and stop frequencies.
/// - ``single``: A single frequency point.
public enum FrequencySweep: Sendable {

    /// Logarithmic sweep with a fixed number of points per decade.
    case decade(start: Double, stop: Double, pointsPerDecade: Int)

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
