import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDIContracts

public struct OSDIPreparedDevice: ~Copyable, Sendable {
    public let instance: Instance
    public let receipt: OSDIPreparationReceipt
    package let owner: OSDIExecutionOwner
    package let projection: OSDITopologyProjection
    package let noiseSources: [ResidualNoiseSource]
    package let hasReactiveResidual: Bool
    public let transientPrecisionReceipt: OSDITransientPrecisionReceipt?
    let constitutiveSnapshot: OSDIConstitutiveSnapshot?

    init(instance: Instance, receipt: OSDIPreparationReceipt, owner: OSDIExecutionOwner,
        projection: OSDITopologyProjection, noiseSources: [ResidualNoiseSource], hasReactiveResidual: Bool,
        transientPrecisionReceipt: OSDITransientPrecisionReceipt?, constitutiveSnapshot: OSDIConstitutiveSnapshot? = nil) {
        self.instance = instance; self.receipt = receipt; self.owner = owner; self.projection = projection
        self.noiseSources = noiseSources; self.hasReactiveResidual = hasReactiveResidual
        self.transientPrecisionReceipt = transientPrecisionReceipt; self.constitutiveSnapshot = constitutiveSnapshot
    }

    public consuming func bind(context: inout BindingContext) throws(OSDIAdapterFailure) -> any BoundDevice {
        guard !Task.isCancelled else { throw .cancelled }
        guard context.operatingConditions.temperatureKelvin == receipt.effectiveTemperatureKelvin else { throw .conditionsMismatch }
        let mapping = try OSDIBoundMapping(projection: projection, context: context)
        do {
            try context.validateOwnedNodes(for: instance)
            try context.validateOwnedBranches(for: instance)
        } catch { throw .invalidMatrixMapping }
        let bound = BoundOSDIDevice(instance: instance, owner: owner, mapping: mapping,
            residualNoiseSources: noiseSources, hasReactiveResidual: hasReactiveResidual, transientPrecisionReceipt: transientPrecisionReceipt, constitutiveSnapshot: constitutiveSnapshot)
        context.commitValidatedOwnedNodes(for: instance)
        context.commitValidatedOwnedBranches(for: instance)
        return bound
    }
}
