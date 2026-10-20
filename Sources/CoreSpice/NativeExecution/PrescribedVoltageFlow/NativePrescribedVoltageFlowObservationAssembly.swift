import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceIO
import CoreSpiceParsedIR

internal enum NativePrescribedVoltageFlowObservationAssembly {
    typealias E = CompensatedEnclosure
    typealias Failure = NativePrescribedVoltageFlowObservationFailure
    typealias Output = NativePrescribedVoltageFlowVoltageObservations

    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (next, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw Failure.capacityExceeded }
        return next
    }
    private static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (next, overflow) = a.multipliedReportingOverflow(by: b)
        guard a >= 0, b >= 0, !overflow else { throw Failure.capacityExceeded }
        return next
    }
    internal static func storageBytes(pairCount: Int, axisCount: Int)
        throws -> (retained: Int, workspace: Int, metadata: Int) {
        let result = try add(MemoryLayout<(NativePrescribedVoltageFlow, Output.Storage)>.stride,
            multiply(pairCount, MemoryLayout<NativePrescribedVoltageFlowVoltageObservation>.stride))
        // Actual lower stored fields, not allocator headers or RSS; the four n-cell buffers use lower leases.
        let metadata = try add(
            MemoryLayout<(PrescribedVoltageReduction.Plan, [E], [E], [E], any Sendable)>.stride,
            MemoryLayout<(PrescribedVoltageReduction.Plan, [E], any Sendable)>.stride)
        return try (result, add(metadata, multiply(try multiply(axisCount, 4), MemoryLayout<E>.stride)), metadata)
    }
    internal static func electricalRow(node: Node, variableMap: [MNAVariable: Int],
        plan: PrescribedVoltageReduction.Plan) throws -> Int? {
        if node == .ground { return nil }
        guard let row = variableMap[.nodeVoltage(node)], (0..<plan.axisCount).contains(row) else {
            throw Failure.unknownNode(node)
        }
        guard try plan.nature(at: row) == .electricalPotential else { throw Failure.nonElectricalNode(node) }
        return row
    }
    static func observe(payload: borrowing NativePrescribedVoltageFlow.Payload,
        pairs: borrowing Span<NativePrescribedVoltageFlowVoltagePair>,
        limits: NativePrescribedVoltageFlowObservationLimits, cancellation: CancellationToken)
        throws(Failure) -> Output.Storage {
        do {
            let record = payload.preparation
            let evolution = payload.evolution
            let window = try payload.chart.evolutionPayload(record: record)
            let initial = try payload.initialRoot.initialPayload(record: record)
            let source = try window.values.reconstructionPayload(record: record)
            let initialValues = try initial.checkedQValues.reconstructionPayload(record: record)
            let control = window.control, n = source.plan.axisCount, p = pairs.count
            func tick(_ units: Int = 1) throws {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
                try control.checkpoint(workUnits: units)
                guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
            }
            try tick(0)
            guard p > 0, limits.maximumPairCount > 0,
                  limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0 else { throw Failure.invalidInput }
            guard p <= limits.maximumPairCount else { throw Failure.capacityExceeded }
            guard source.plan.axisCount == initialValues.plan.axisCount,
                source.plan.reducedCount == initialValues.plan.reducedCount,
                source.plan.axisCount == record.plan.topology.dimension, initial.control === control else {
                throw NativePrescribedVoltageEvolutionFailure.invalidBinding
            }
            for pair in pairs {
                try tick(2)
                _ = try electricalRow(node: pair.positive, variableMap: record.plan.topology.variableMap, plan: source.plan)
                _ = try electricalRow(node: pair.reference, variableMap: record.plan.topology.variableMap, plan: source.plan)
            }
            let bytes = try storageBytes(pairCount: p, axisCount: n)
            guard bytes.retained <= limits.maximumRetainedBytes, bytes.workspace <= limits.maximumWorkspaceBytes else {
                throw Failure.capacityExceeded
            }
            let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(bytes.retained))
            guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
            let metadata = try control.reserveStorage(byteCount: bytes.metadata)
            defer { withExtendedLifetime(metadata) {} }
            try tick(p)
            var observations: [NativePrescribedVoltageFlowVoltageObservation] = []
            observations.reserveCapacity(p)
            try tick(0)
            let rates = try payload.evolution.voltageRateLift(record: record, cancellation: cancellation)
            try tick(0)
            let zero = try E(center: .zero)
            for pair in pairs {
                try tick(8)
                let positive = try electricalRow(node: pair.positive, variableMap: record.plan.topology.variableMap, plan: source.plan)
                let reference = try electricalRow(node: pair.reference, variableMap: record.plan.topology.variableMap, plan: source.plan)
                let initialVoltage: E, windowVoltage: E, rate: E
                if positive == reference {
                    initialVoltage = zero; windowVoltage = zero; rate = zero
                } else {
                    initialVoltage = try (positive.map { try initialValues.lift.coordinate(at: $0) } ?? zero)
                        .subtracting(reference.map { try initialValues.lift.coordinate(at: $0) } ?? zero)
                    windowVoltage = try (positive.map { try evolution.coordinate(at: $0, side: .left) } ?? zero)
                        .subtracting(reference.map { try evolution.coordinate(at: $0, side: .left) } ?? zero)
                    rate = try (positive.map { try rates.coordinate(at: $0) } ?? zero)
                        .subtracting(reference.map { try rates.coordinate(at: $0) } ?? zero)
                }
                observations.append(.init(pair: pair, initialVoltage: initialVoltage,
                    windowVoltage: windowVoltage, almostEverywhereRate: rate))
            }
            try tick(0)
            return .init(observations: observations, lease: lease)
        } catch let failure as Failure { throw failure }
        catch AnalysisError.cancelled { throw .cancelled }
        catch NativeConstitutivePreparationControl.Failure.cancelled { throw .cancelled }
        catch SPICESimulationResources.ResourceError.cancelled { throw .cancelled }
        catch is CancellationError { throw .cancelled }
        catch { throw .operation(cause: error) }
    }
}
