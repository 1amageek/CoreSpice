import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI

extension NativeCircuitExecution {
    static func failure(_ error: any Error, closing records: [NativeCircuitPreparationRecord]) -> SPICENativeExecutionError {
        var owners: [OSDIExecutionOwner] = []
        var seen = Set<ObjectIdentifier>()
        var reservations = records.flatMap(\.reservations)
        func retain(_ lifetime: OSDIExecutionLifetime) {
            for owner in lifetime.owners where seen.insert(ObjectIdentifier(owner)).inserted { owners.append(owner) }
        }
        for record in records { if let lifetime = record.osdiLifetime { retain(lifetime) } }
        var causes: [any Error] = [error]
        while let cause = causes.popLast() {
            let pending: SPICEOSDICleanupFailure
            switch cause {
            case let value as SPICEOSDICleanupFailure: pending = value
            case SPICENativeExecutionError.osdiCleanup(let value): pending = value
            case SPICENativePreparationError.osdiCleanup(let value): pending = value
            default: continue
            }
            retain(pending.lifetime)
            // Reservation copies share one exactly-once refund owner; no capacity is charged again.
            reservations.append(contentsOf: pending.reservations)
            causes.append(pending.primary)
        }
        guard !owners.isEmpty else { return failure(error) }
        let lifetime = OSDIExecutionLifetime(owners: owners)
        do { try lifetime.close() }
        catch let secondary {
            return .osdiCleanup(.init(primary: error, secondary: secondary,
                lifetime: lifetime, reservations: reservations))
        }
        return failure(error)
    }

    static func configuredTransientAnalysis(_ analysis: TransientAnalysis,
        record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        cancellation: CancellationToken, budget: TransientExecutionBudget,
        finalizeOnCompletion: Bool = true) throws -> TransientAnalysis {
        guard let lifetime = record.osdiLifetime else { return analysis }
        var sourceFactWork: UInt64 = 0
        for owner in lifetime.owners {
            sourceFactWork = try capacitySum(sourceFactWork, UInt64(owner.transientSourceFactWork()))
        }
        guard let admittedSourceFactWork = Int(exactly: sourceFactWork) else {
            throw SPICENativeExecutionError.resource(TransientExecutionError.arithmeticOverflow("source fact work"))
        }
        // Fixed source-record initialization is charged once in addition to each subsequent use.
        try budget.chargeWork(admittedSourceFactWork)
        let validator = try physicalValidator(record: record, devices: devices,
            config: analysis.convergenceConfig, cancellation: cancellation, prior: analysis.operatingPointValidator)
        let canonical = try NativeOSDICanonicalTransientValidator(devices: devices,
            precision: record.osdiRuntimeInputs?.transientPrecision != nil, rows: validator.rows,
            variableMap: record.plan.topology.variableMap, budget: budget, cancellation: cancellation,
            sourceFactWork: admittedSourceFactWork, osdiOwners: lifetime.owners)
        let selectedEncloser: (any TransientPhysicalResidualEnclosing)?
        let selectedValidator: (any TransientPhysicalResidualValidating)?
        if record.osdiRuntimeInputs?.transientPrecision != nil {
            guard analysis.physicalResidualEncloser == nil else {
                throw SPICENativeExecutionError.unsupportedCapability("Multiple complete transient precision providers")
            }
            let contributors = try devices.map { device -> any TransientPhysicalResidualEnclosureContributing in
                guard let contributor = device as? any TransientPhysicalResidualEnclosureContributing else {
                    throw SPICENativeExecutionError.unsupportedCapability("Missing paired original transient equation")
                }
                return contributor
            }
            selectedEncloser = NativeOSDITransientEncloser(contributors: contributors,
                rowCount: validator.rows.count, cancellation: cancellation, prior: analysis.physicalResidualValidator, canonical: canonical,
                sourceFactBudget: budget, sourceFactWork: admittedSourceFactWork)
            selectedValidator = nil
        } else {
            let contributors = try devices.map { device -> any TransientPhysicalResidualContributing in
                guard let contributor = device as? any TransientPhysicalResidualContributing else {
                    throw SPICENativeExecutionError.unsupportedCapability("Missing original physical transient equation")
                }
                return contributor
            }
            selectedEncloser = analysis.physicalResidualEncloser
            selectedValidator = NativeOSDITransientValidator(contributors: contributors, rows: validator.rows,
                workspace: validator.workspace, cancellation: cancellation, prior: analysis.physicalResidualValidator, canonical: canonical,
                sourceFactBudget: budget, sourceFactWork: admittedSourceFactWork)
        }
        var selectedVariables = errorControlVariables(devices: devices, variableMap: record.plan.topology.variableMap)
        if let requested = analysis.errorControlVariables {
            let full = Set(record.plan.topology.variableMap.keys)
            guard requested == full || requested == selectedVariables else {
                throw SPICENativeExecutionError.unsupportedCapability("Transient error control differs from the structural Native profile")
            }
            selectedVariables = requested
        }
        let priorAccepted = analysis.onStepAccepted
        return TransientAnalysis(config: analysis.config, convergenceConfig: analysis.convergenceConfig,
            onStepAccepted: { time, values in
                canonical.promote(time: time)
                priorAccepted?(time, values)
            }, equationPolicy: try .init(rows: validator.rows),
            operatingPointValidator: validator, physicalResidualValidator: selectedValidator,
            completionFinalizer: NativeOSDICanonicalCompletionFinalizer(validator: canonical,
                prior: finalizeOnCompletion
                    ? NativeOSDICompletionFinalizer(record: record, cancellation: cancellation, prior: analysis.completionFinalizer) : nil),
            errorControlVariables: selectedVariables, physicalResidualEncloser: selectedEncloser)
    }

    static func validateTransientResult(_ result: TransientResult, config: TransientConfig, precision: Bool) throws {
        guard result.timePoints.last == config.stopTime, result.executionStatistics != nil,
              result.solutionTrace.rowMajorValues.allSatisfy({ $0.isFinite }) else {
            throw SPICENativeExecutionError.invalidOutput
        }
        if precision {
            guard let lowTrace = result.solutionLowTrace,
                  lowTrace.variableCount == result.solutionTrace.variableCount,
                  lowTrace.pointCount == result.timePoints.count,
                  result.acceptedSteps.count == result.timePoints.count - 1,
                  result.timeSteps == result.acceptedSteps.count else {
                throw SPICENativeExecutionError.invalidOutput
            }
            for point in result.timePoints.indices {
                try result.withCompensatedSolution(at: point) { high, low in
                    guard let low, low.count == high.count else { throw SPICENativeExecutionError.invalidOutput }
                    for index in high.indices { _ = try CompensatedValue(high: high[index], low: low[index]) }
                }
            }
            for (index, step) in result.acceptedSteps.enumerated() {
                let interval = try CompensatedValue(high: result.timePoints[index + 1])
                    .subtracting(CompensatedValue(high: result.timePoints[index]))
                guard step.time == result.timePoints[index + 1],
                      interval == (try CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent)) else {
                    throw SPICENativeExecutionError.invalidOutput
                }
            }
        }
    }

    /// State LTE excludes only reaction currents proven unread by the admitted device profile.
    static func errorControlVariables(devices: [any BoundDevice], variableMap: [MNAVariable: Int]) -> Set<MNAVariable>? {
        var hasStorage = false
        var sources = Set<MNAVariable>()
        for (index, device) in devices.enumerated() {
            if let osdi = device as? any OSDIReactiveResidualProviding {
                guard device.instance.osdi != nil else { return nil }
                hasStorage = hasStorage || osdi.hasReactiveResidual
            } else if device is BoundCapacitor || device is BoundInductor {
                hasStorage = true
            } else if device is BoundVoltageSource {
                guard device.instance.ownedBranches.count == 1, let branch = device.instance.ownedBranches.first,
                      variableMap[.branchCurrent(branch)] != nil else { return nil }
                for (otherIndex, other) in devices.enumerated() where otherIndex != index {
                    guard !other.instance.ownedBranches.contains(branch),
                          !other.instance.referencedBranches.contains(branch) else { return nil }
                }
                guard sources.insert(.branchCurrent(branch)).inserted else { return nil }
            } else if !(device is BoundResistor || device is BoundCurrentSource) {
                return nil
            }
        }
        if !hasStorage { return [] }
        guard !sources.isEmpty else { return nil }
        var controlled = Set(variableMap.keys)
        controlled.subtract(sources)
        return controlled
    }

    static func physicalValidationCapacity(_ record: NativeCircuitPreparationRecord) throws -> UInt64 {
        guard record.osdiLifetime != nil else { return 0 }
        // Four new logical set roles: source IDs, selected variables, explicit-full comparison,
        // and generic excluded indices. Two entry planes per role cover construction/COW
        // coexistence. This admits logical capacity; it does not model Swift Set buckets or RSS.
        let rows = try capacityProduct(UInt64(record.plan.topology.dimension),
            UInt64(MemoryLayout<DCEquationRowPolicy?>.stride + MemoryLayout<DCEquationRowPolicy>.stride + 2 * MemoryLayout<Double>.stride
                + 8 * (MemoryLayout<MNAVariable>.stride + MemoryLayout<Int>.stride)
                + 3 * MemoryLayout<CompensatedEnclosure>.stride))
        // Both DC and transient contributor existential arrays coexist for transient.
        let transientStride = record.osdiRuntimeInputs?.transientPrecision == nil
            ? MemoryLayout<any TransientPhysicalResidualContributing>.stride
            : MemoryLayout<any TransientPhysicalResidualEnclosureContributing>.stride
        let devices = try capacityProduct(UInt64(record.plan.ir.instances.count),
            UInt64(MemoryLayout<any DCPhysicalResidualContributing>.stride + transientStride
                + max(MemoryLayout<any TransientPhysicalEquationDecomposing>.stride,
                    MemoryLayout<any TransientPhysicalEquationEnclosureDecomposing>.stride)))
        return try capacitySum(capacitySum(rows, devices), UInt64(NativeOSDICanonicalTransientValidator.logicalStateByteCount
            + 2 * (MemoryLayout<TransientExecutionBudget?>.stride + MemoryLayout<Int>.stride)))
    }

    static func physicalValidator(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
                                  config: ConvergenceConfig, cancellation: CancellationToken,
                                  prior: (any DCPhysicalResidualValidating)? = nil,
                                  policy: DCEquationPolicy? = nil) throws -> NativeOSDIPhysicalValidator {
        let policy = try policy ?? NativeOSDIPhysicalValidator.policy(record: record, config: config)
        let contributors = try devices.map { device -> any DCPhysicalResidualContributing in
            guard let contributor = device as? any DCPhysicalResidualContributing else {
                throw SPICENativeExecutionError.unsupportedCapability("Missing original physical DC equation")
            }
            return contributor
        }
        return .init(contributors: contributors, rows: policy.rows, cancellation: cancellation, prior: prior)
    }

    static func phases(record: NativeCircuitPreparationRecord, operatingPoint: DCResult?,
                       analysis: String, points: Int, reservation: NativeExecutionStorage,
                       equationPolicy: DCEquationPolicy? = nil) -> [NativeCircuitExecutionFacts] {
        var phases: [NativeCircuitExecutionFacts] = []
        if operatingPoint != nil { phases.append(.init(record: record, instances: record.plan.ir.instances,
            analysis: "op", completedPointCount: 1, reservation: reservation, equationPolicy: equationPolicy)) }
        phases.append(.init(record: record, instances: record.plan.ir.instances, analysis: analysis,
            completedPointCount: points, reservation: reservation, equationPolicy: equationPolicy))
        return phases
    }
}
