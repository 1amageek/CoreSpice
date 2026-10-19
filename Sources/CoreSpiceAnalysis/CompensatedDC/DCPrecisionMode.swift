/// Selects the coordinate representation used by a DC invocation.
public enum DCPrecisionMode: Sendable {
    /// Uses complete paired equations when every admitted device supports them.
    case automatic
    /// Uses the ordinary binary64 coordinate path.
    case binary64
    /// Requires complete compensated coordinates and original-equation enclosures.
    case compensated
}
