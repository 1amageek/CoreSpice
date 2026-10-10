/// A concrete invocation input; constants do not require extending the immutable snapshot.
public enum MOSInvocationValue: Sendable, Hashable {
    case program(MOSProgramID)
    case constant(Double)
}
