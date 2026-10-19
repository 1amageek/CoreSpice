/// Physical variable and equation units for one compiled DC row.
public enum DCEquationKind: Sendable, Equatable {
    /// Voltage in V with a current-balance equation in A.
    case electricalPotential
    /// Branch current in A with a voltage equation in V.
    case electricalFlow
    /// Temperature rise in K with a power-balance equation in W.
    case thermalPotential

    var allowsGmin: Bool { self == .electricalPotential }
}
