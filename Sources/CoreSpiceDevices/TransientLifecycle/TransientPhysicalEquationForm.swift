/// The original reactive operator supplied by a bound device.
public enum TransientPhysicalEquationForm: Sendable, Equatable {
    /// A conservative coordinate Q, including identically zero reactive charge.
    case chargeDifference
    /// Differential C(V,t)*D(V), with its separately identified coefficient-history correction.
    case differentialCapacitance
}
