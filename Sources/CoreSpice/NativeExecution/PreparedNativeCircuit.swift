import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import CoreSpiceParsedIR
import CoreSpiceEvent

/// A single-use native circuit; only concrete analysis operations can consume its devices.
public struct PreparedNativeCircuit: ~Copyable, Sendable {
    public let record: NativeCircuitPreparationRecord
    public var plan: ExecutionPlan { record.plan }
    private let devices: [any BoundDevice]
    internal init(record: NativeCircuitPreparationRecord, devices: [any BoundDevice]) {
        self.record = record; self.devices = devices
    }
    public func close() throws(OSDIAdapterFailure) { try record.osdiLifetime?.close() }
    /// Borrows actual checked native source values without consuming or closing this circuit.
    public borrowing func withIndependentVoltageSources<Result>(cancellation: CancellationToken,
        _ body: (borrowing NativeVoltageSourceInspectionView) throws -> Result)
        throws(NativeVoltageSourceInspectionFailure) -> Result {
        try inspectIndependentVoltageSources(origin: .circuit, cancellation: cancellation, body)
    }
    internal borrowing func inspectIndependentVoltageSources<Result>(origin: NativeVoltageSourceInspectionOrigin,
        cancellation: CancellationToken, _ body: (borrowing NativeVoltageSourceInspectionView) throws -> Result)
        throws(NativeVoltageSourceInspectionFailure) -> Result {
        try NativeVoltageSourceInspection.inspect(record: record, devices: devices, origin: origin,
            cancellation: cancellation, body)
    }
    /// Opens only an actual OSDI device after the complete exclusive-owner association has been checked.
    // Actual-bound preparation, shared admission and cleanup are qualified on the finite pinned fixtures.
    // Conditional capture grants no global kernel, root, flow or history authority.
    package borrowing func prepareConstitutiveCapture(at index: Int, inputs: OSDIConstitutiveCaptureInputs,
        cancellation: CancellationToken) async throws -> OSDIConstitutiveCapture {
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        guard devices.indices.contains(index), devices[index].instance.osdi != nil else {
            throw NativeConstitutiveInspection.Failure.invalidBinding
        }
        var capture = try await OSDIConstitutiveBoundDeviceAccess.prepareCapture(of: devices[index], inputs: inputs)
        if cancellation.isCancelled || Task.isCancelled {
            let cancelled = NativeConstitutiveInspection.Failure.cancelled
            do { try capture.close() }
            catch OSDIConstitutiveCaptureFailure.cleanupPending(let primary, let secondary, let owner) {
                throw OSDIConstitutiveCaptureFailure.cleanupPending(
                    primary: .cleanup(primary: .control(cancelled), secondary: primary), secondary: secondary, owner: owner)
            } catch let failure as OSDIConstitutiveCaptureFailure {
                throw OSDIConstitutiveCaptureFailure.cleanup(primary: .control(cancelled), secondary: failure)
            } catch {
                throw OSDIConstitutiveCaptureFailure.cleanup(primary: .control(cancelled), secondary: .control(error))
            }
            throw cancelled
        }
        return consume capture
    }

    /// Checks one finite conditional source-flow slab using only this actual controlled owner.
    public borrowing func certifyPrescribedVoltageFlow(request: NativePrescribedVoltageFlowRequest,
        capture: OSDIConstitutiveCaptureInputs?, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageFlowLimits, cancellation: CancellationToken)
        async throws(NativePrescribedVoltageFlowFailure) -> NativePrescribedVoltageFlow {
        try await NativePrescribedVoltageFlow.certify(record: record, devices: devices,
            request: request, capture: capture, range: range, limits: limits, cancellation: cancellation)
    }

    /// Uses only this owner's retained chart/source planes; it performs no model query.
    package borrowing func reconstructPrescribedVoltageChart(chart: NativePrescribedVoltageChart,
        limits: NativePrescribedVoltageEvolutionLimits, cancellation: CancellationToken) throws -> NativePrescribedVoltageEvolution {
        try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
        return try NativePrescribedVoltageEvolution.reconstruct(record: record, chart: chart, limits: limits, cancellation: cancellation)
    }

    /// Certifies only one source-bound coordinate charge chart on an explicit parameter slab.
    package borrowing func certifyPrescribedVoltageChart(values: NativePrescribedVoltageValues,
        algebraicRows: [Int], chargeParameters: [CompensatedEnclosure], center: [CompensatedValue],
        inverse: SparseStructure, inverseValues: [Double], capture: OSDIConstitutiveCaptureInputs?,
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageChartLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageChart {
        try await NativePrescribedVoltageChart.certify(record: record, devices: devices, values: values,
            algebraicRows: algebraicRows, chargeParameters: chargeParameters, center: center,
            inverse: inverse, inverseValues: inverseValues, capture: capture, range: range,
            limits: limits, cancellation: cancellation)
    }

    /// Checks an explicit initial coordinate set, then queries its actual source charge.
    package borrowing func certifyPrescribedVoltageInitialRoot(values: NativePrescribedVoltageValues,
        algebraicRows: [Int], dynamicInitialCoordinates: [CompensatedEnclosure], center: [CompensatedValue],
        inverse: SparseStructure, inverseValues: [Double], capture: OSDIConstitutiveCaptureInputs?,
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageChartLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageInitialRoot {
        try await NativePrescribedVoltageInitialRoot.certify(record: record, devices: devices, values: values,
            algebraicRows: algebraicRows, dynamicInitialCoordinates: dynamicInitialCoordinates, center: center,
            inverse: inverse, inverseValues: inverseValues, capture: capture, range: range,
            limits: limits, cancellation: cancellation)
    }

    /// Checks a complete conditional Q kernel using only this owner's actual producers.
    package borrowing func certifyGlobalChargeKernel(domain: NativeGlobalChargeDomain,
        proposal: NativeGlobalChargeProposal, capture: OSDIConstitutiveCaptureInputs?,
        limits: NativeGlobalChargeLimits, cancellation: CancellationToken) async throws -> NativeGlobalChargeKernel {
        try await NativeGlobalChargeKernel.certify(record: record, devices: devices, domain: domain,
            proposal: proposal, capture: capture, limits: limits, cancellation: cancellation)
    }

    /// Conditional same-owner prescribed-source F0/Q values; ordinary execution is unchanged.
    package borrowing func enclosePrescribedVoltageValues(originalDomain: NativeGlobalChargeDomain,
        sources: [NativePrescribedVoltageSource], reducedCoordinates: [CompensatedEnclosure],
        capture: OSDIConstitutiveCaptureInputs?, limits: NativePrescribedVoltageLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageValues {
        try await NativePrescribedVoltageValues.enclose(record: record, devices: devices,
            originalDomain: originalDomain, sources: sources, reducedCoordinates: reducedCoordinates,
            capture: capture, limits: limits, cancellation: cancellation)
    }

    /// Reconstructs both one-sided conditional source currents on the original smooth domain.
    package borrowing func reconstructPrescribedVoltageCurrents(values: NativePrescribedVoltageValues,
        leftReducedRates: [CompensatedEnclosure], rightReducedRates: [CompensatedEnclosure],
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageReconstructionLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageReconstruction {
        try await NativePrescribedVoltageReconstruction.reconstruct(record: record, devices: devices,
            values: values, leftReducedRates: leftReducedRates, rightReducedRates: rightReducedRates,
            range: range, limits: limits, cancellation: cancellation)
    }

    /// Assembles the full-original-domain mass and explicit-slab one-sided drifts.
    package borrowing func assemblePrescribedVoltageMass(values: NativePrescribedVoltageValues,
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageMassLimits,
        cancellation: CancellationToken) async throws -> NativePrescribedVoltageMass {
        try await NativePrescribedVoltageMass.assemble(record: record, devices: devices,
            values: values, range: range, limits: limits, cancellation: cancellation)
    }

    /// Shares invocation-wide numerical counters while preserving this circuit's fixed limits and layout.
    public consuming func usingExecutionResources(_ resources: AnalysisExecutionResources) throws -> Self {
        Self(record: try record.usingExecutionResources(resources), devices: devices)
    }
    internal consuming func reservingRetainedStorage(byteCount: UInt64) throws -> Self {
        Self(record: try record.reservingRetainedStorage(byteCount: byteCount), devices: devices)
    }
    internal consuming func takeState() -> (NativeCircuitPreparationRecord, [any BoundDevice]) { (record, devices) }
}
