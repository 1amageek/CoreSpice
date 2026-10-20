import CoreSpiceIR
import CoreSpiceDevices
import OSDIContracts

public protocol OSDICircuitPreparing: Sendable {
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?,
        simulationParameters: [OSDISimulationParameter]) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit

}

public extension OSDICircuitPreparing {
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
        guard transientPrecision == nil else { throw .unsupportedAnalysis }
        return try await prepare(ir: ir, operatingConditions: operatingConditions, provider: provider,
            loadLimits: loadLimits, evaluationLimits: evaluationLimits, maximumInstanceCount: maximumInstanceCount,
            maximumAdapterBytes: maximumAdapterBytes)
    }
    func prepare(ir: CircuitIR, operatingConditions: OperatingConditions,
        provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
        evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
        maximumAdapterBytes: UInt64, transientPrecision: OSDITransientPrecisionInputs?,
        simulationParameters: [OSDISimulationParameter]) async throws(OSDIAdapterFailure) -> OSDIPreparedCircuit {
        guard simulationParameters.isEmpty else { throw .unsupportedAnalysis }
        return try await prepare(ir: ir, operatingConditions: operatingConditions, provider: provider,
            loadLimits: loadLimits, evaluationLimits: evaluationLimits, maximumInstanceCount: maximumInstanceCount,
            maximumAdapterBytes: maximumAdapterBytes, transientPrecision: transientPrecision)
    }

}
