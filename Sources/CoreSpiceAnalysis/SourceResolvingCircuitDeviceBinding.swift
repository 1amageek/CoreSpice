import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceDevices

/// Reexecutes captured source and prepares fresh complete circuit owners for scalar replacements.
///
/// `bind(plan:instances:cancellation:)` treats changed scalar parameters as source replacements,
/// preserves original source/conditions provenance, and returns the newly compiled
/// plan with fresh devices. It never mutates or reuses immutable prepared receipts.
/// Retained source and native preparation resources belong to the binding owner.
public protocol SourceResolvingCircuitDeviceBinding: CircuitDeviceBinding {
    /// Enumerates supported source replacements, including role-qualified model parameters.
    func sensitivityParameters(
        in plan: ExecutionPlan,
        cancellation: CancellationToken
    ) throws -> [CircuitSensitivityParameter]

    /// Installs the actual baseline/fresh child's physical policy while preserving supplied resources and guesses.
    func configureDCAnalysis(_ analysis: DCAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                             cancellation: CancellationToken) throws -> DCAnalysis

    /// Installs the actual baseline/fresh child's AC/OP physical policy and completion boundary.
    func configureACAnalysis(_ analysis: ACAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                             cancellation: CancellationToken) throws -> ACAnalysis
}

extension SourceResolvingCircuitDeviceBinding {
    public func configureDCAnalysis(_ analysis: DCAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                                    cancellation: CancellationToken) throws -> DCAnalysis { analysis }
    public func configureACAnalysis(_ analysis: ACAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                                    cancellation: CancellationToken) throws -> ACAnalysis { analysis }
}
