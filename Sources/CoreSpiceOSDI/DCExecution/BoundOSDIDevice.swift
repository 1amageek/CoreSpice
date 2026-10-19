import CoreSpiceIR
import CoreSpiceDevices

struct BoundOSDIDevice: BoundDevice, OSDIPhysicalResidualContributing, TransientSessionDevice,
    TransientPhysicalResidualContributing, TransientTimeStepConstraintDevice,
    TransientTrialTimeStepConstraintDevice, ResidualNoisyDevice, NoiseMatrixStampingDevice,
    OSDIReactiveResidualProviding, OSDITransientPrecisionProviding, TransientPhysicalResidualEnclosureContributing,
    TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing {
    let instance: Instance
    let owner: OSDIExecutionOwner
    let mapping: OSDIBoundMapping
    let residualNoiseSources: [ResidualNoiseSource]
    let hasReactiveResidual: Bool
    let transientPrecisionReceipt: OSDITransientPrecisionReceipt?
    let constitutiveSnapshot: OSDIConstitutiveSnapshot?

    init(instance: Instance, owner: OSDIExecutionOwner, mapping: OSDIBoundMapping,
        residualNoiseSources: [ResidualNoiseSource], hasReactiveResidual: Bool,
        transientPrecisionReceipt: OSDITransientPrecisionReceipt?, constitutiveSnapshot: OSDIConstitutiveSnapshot? = nil) {
        self.instance = instance; self.owner = owner; self.mapping = mapping
        self.residualNoiseSources = residualNoiseSources; self.hasReactiveResidual = hasReactiveResidual
        self.transientPrecisionReceipt = transientPrecisionReceipt; self.constitutiveSnapshot = constitutiveSnapshot
    }

    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try owner.stamp(mapping: mapping, stamper: &stamper, solution: state)
    }
    func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        try owner.accumulatePhysicalResidual(mapping: mapping, solution: state, add: add)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try owner.stampComplex(mapping: mapping, stamper: &stamper, solution: state, omega: omega, noise: false)
    }
    func stampNoiseMatrix(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try owner.stampComplex(mapping: mapping, stamper: &stamper, solution: state, omega: omega, noise: true)
    }
    func withNoiseDensities(state: SolutionState, frequency: Double,
                           _ body: (borrowing Span<Double>) throws -> Void) throws {
        try owner.withNoiseDensities(mapping: mapping, solution: state, frequency: frequency,
            expectedCount: residualNoiseSources.count, body)
    }
    var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    func validateTransientPhysicalEquationDecomposition() throws {
        // Preparation already admitted complete raw F/Q outputs for this exact descriptor.
    }
    func accumulateTransientStaticResidual(state: SolutionState, time: Double, add: (Int, Double) -> Void) throws {
        try owner.initialStaticResidual(mapping: mapping, solution: state, time: time) { row, value, _ in add(row, value.high + value.low) }
    }
    func accumulateTransientStaticResidualEnclosure(state: SolutionState, time: Double,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        try owner.initialStaticResidual(mapping: mapping, solution: state, time: time, add: add)
    }
    func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        try owner.decomposeTransient(mapping: mapping, solution: state, integration: integration, add: add)
    }
    func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
        try owner.decomposeTransientEnclosure(mapping: mapping, solution: state, integration: integration, add: add)
    }
    func beginTransientSession(initialState: SolutionState) throws {
        try beginTransientSession(initialState: initialState, initialization: .operatingPoint)
    }
    func beginTransientSession(initialState: SolutionState, initialization: TransientInitialization) throws {
        try owner.beginTransient(mapping: mapping, solution: initialState, initialization: initialization)
    }
    func endTransientSession() { owner.endTransient() }
    var maximumTransientTimeStep: Double { owner.maximumTransientTimeStep }
    func maximumTransientTimeStep(state: SolutionState, integration: IntegrationState) throws -> Double? {
        try owner.candidateMaximumTimeStep(mapping: mapping, solution: state, integration: integration)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try owner.stampTransient(mapping: mapping, stamper: &stamper, solution: state, integration: integration)
    }
    func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState,
                                             add: (Int, Double) -> Void) throws {
        try owner.accumulateTransientResidual(mapping: mapping, solution: state, integration: integration, add: add)
    }
    func accumulateTransientPhysicalResidualEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        try owner.accumulateTransientEnclosure(mapping: mapping, solution: state, integration: integration, add: add)
    }
    func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        try owner.commitTransient(mapping: mapping, solution: state, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
}
