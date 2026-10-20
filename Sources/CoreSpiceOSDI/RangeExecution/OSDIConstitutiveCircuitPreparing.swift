import CoreSpiceIR
import CoreSpiceDevices
import OSDIContracts

/// The package factory boundary for actual controlled constitutive snapshots.
package protocol OSDIConstitutiveCircuitPreparing: OSDICircuitPreparing {
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?,
        constitutiveSnapshot: OSDIConstitutiveSnapshotInputs?,
        simulationParameters: [OSDISimulationParameter]?) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit
}

package extension OSDIConstitutiveCircuitPreparing {
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?,
        constitutiveSnapshot: OSDIConstitutiveSnapshotInputs?) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
        try await prepare(ir: ir, operatingConditions: operatingConditions, provider: provider,
            loadLimits: loadLimits, evaluationLimits: evaluationLimits, maximumInstanceCount: maximumInstanceCount,
            maximumAdapterBytes: maximumAdapterBytes, transientPrecision: transientPrecision,
            constitutiveSnapshot: constitutiveSnapshot, simulationParameters: nil)
    }
}
