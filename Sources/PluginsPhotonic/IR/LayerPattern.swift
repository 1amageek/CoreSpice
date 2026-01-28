/// Describes the pairing pattern of MZI units within a mesh layer.
///
/// In a photonic mesh, adjacent waveguide ports are paired and fed
/// into MZI interferometers. The pattern determines the starting offset:
///
/// - `even`: pairs at indices (0,1), (2,3), (4,5), ...
/// - `odd`:  pairs at indices (1,2), (3,4), (5,6), ...
public enum LayerPattern: UInt32, Sendable, Codable {

    /// Pairs start at port 0: (0,1), (2,3), (4,5), ...
    case even = 0

    /// Pairs start at port 1: (1,2), (3,4), (5,6), ...
    case odd = 1
}
