/// Optional distinct matrix evaluation context for noise; pure AC keeps stampAC.
public protocol NoiseMatrixStampingDevice: BoundDevice {
    func stampNoiseMatrix(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws
}
