/// The physical network quantity represented by each matrix.
public enum TouchstoneParameterKind: String, Sendable, Equatable {
    case scattering = "S"
    case admittance = "Y"
    case impedance = "Z"
}
