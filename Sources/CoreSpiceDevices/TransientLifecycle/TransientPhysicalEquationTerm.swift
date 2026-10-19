/// Distinguishes physical terms without relabeling a differential law as conservative charge.
public enum TransientPhysicalEquationTerm: Sendable, Equatable {
    case staticResidual
    /// Unadjusted alpha*(Qcandidate-Qaccepted).
    case chargeDifference
    /// Ccandidate*alpha*(Vcandidate-Vaccepted).
    case differentialIncrement
    /// TR coefficient correction (Caccepted-Ccandidate)*Daccepted; absent for BE.
    case differentialHistoryCorrection
}
