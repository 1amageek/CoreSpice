/// Applicability of the finite generalized-eigenvalue pole-zero realization.
public enum PoleZeroStampApplicability: Sendable, Equatable {
    /// At fixed bias, the complete matrix is exactly G + j*omega*C with real constant G and C.
    case affine
    /// The matrix has another frequency dependence or its realization is not established.
    case unsupported(reason: String)
}

// These device-owned stamps contain only fixed-bias static terms and omega-scaled charge terms.
extension BoundResistor { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundRuntimeResistor { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundCapacitor { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundInductor { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundMutualInductance { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundVoltageSource { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundCurrentSource { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundVCCS { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundVCVS { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundCCCS { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundCCVS { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundBranchReferencedCCCS { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundBranchReferencedCCVS { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundVoltageControlledSwitch { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundCurrentControlledSwitch { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundBranchReferencedCurrentControlledSwitch { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundBehavioralCurrentSource { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundBehavioralVoltageSource { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundBJT { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundJFET { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundMESFET { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundNMOSL1 { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundNMOSL2 { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundNMOSL3 { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundPMOSL1 { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundPMOSL2 { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundPMOSL3 { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }
extension BoundDiode { public var poleZeroStampApplicability: PoleZeroStampApplicability { .affine } }

extension BoundTransmissionLine {
    public var poleZeroStampApplicability: PoleZeroStampApplicability {
        .unsupported(reason: "A delayed transmission line contains exp(-s*delay) and requires an infinite-spectrum analysis")
    }
}
