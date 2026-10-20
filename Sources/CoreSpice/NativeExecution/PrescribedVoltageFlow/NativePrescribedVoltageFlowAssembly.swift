import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI
import OSDIContracts

internal enum NativePrescribedVoltageFlowAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    typealias Failure = NativePrescribedVoltageFlowFailure
    private enum JoinFailure: Error { case initialBoxOutsideWindow, initialSourceOutsideWindow, chargeDomain }

    static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        request: NativePrescribedVoltageFlowRequest, capture: OSDIConstitutiveCaptureInputs?,
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageFlowLimits,
        cancellation: CancellationToken) async throws(Failure) -> NativePrescribedVoltageFlow.Payload {
        var phase = Failure.Phase.initialValues
        do {
            guard let control = record.constitutiveBacking?.control else { throw Failure.missingControlledPreparation }
            func tick(_ units: Int = 1) throws {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
                try control.checkpoint(workUnits: units)
            }
            try tick(0)
            try NativeConstitutiveInspection.validate(record: record, devices: devices, cancellation: cancellation)
            let n = record.plan.topology.dimension, k = request.initial.coordinates.count
            let m = request.sources.count, b = request.algebraicRows.count
            guard n > 0, request.originalLower.count == n, request.originalUpper.count == n,
                  k > 0, k <= n, b <= k, request.window.coordinates.count == k,
                  request.dynamicInitialCoordinates.count == k - b, request.chargeBox.count == k - b,
                  m <= devices.count,
                  A.ordered(.zero, request.duration), request.duration != .zero,
                  limits.maximumNativeTerms >= 0, limits.maximumTriplets >= 0,
                  limits.maximumPreconditionerNonzeros >= 0, limits.maximumIntegerBits > 0 else { throw Failure.invalidInput }
            guard k - b > 0 else { throw Failure.unsupportedProfile }
            func validate(_ value: NativePrescribedVoltageFlowLimits.Capacity) throws {
                try tick()
                guard value.maximumRetainedBytes > 0, value.maximumWorkspaceBytes > 0 else { throw Failure.invalidInput }
            }
            try validate(limits.values); try validate(limits.reduction); try validate(limits.chart)
            try validate(limits.exact); try validate(limits.root); try validate(limits.evolution); try validate(limits.result)
            let l = k - b, foreign = record.osdiPreparationRecords.count
            var maximumRaw = 1
            for item in record.osdiPreparationRecords { try tick(); maximumRaw = max(maximumRaw, item.receipt.topology.nodes.count) }
            let valuesLimits = NativePrescribedVoltageLimits(maximumNativeTerms: limits.maximumNativeTerms,
                maximumRetainedBytes: limits.values.maximumRetainedBytes, maximumWorkspaceBytes: limits.values.maximumWorkspaceBytes,
                precisionBits: limits.precisionBits,
                reductionLimits: .init(maximumAxes: n, maximumSources: m,
                    maximumWorkspaceBytes: limits.reduction.maximumWorkspaceBytes, maximumResultBytes: limits.reduction.maximumRetainedBytes))
            let chartLimits = NativePrescribedVoltageChartLimits(maximumTriplets: limits.maximumTriplets,
                maximumRetainedBytes: limits.chart.maximumRetainedBytes, maximumWorkspaceBytes: limits.chart.maximumWorkspaceBytes,
                precisionBits: limits.precisionBits, values: valuesLimits,
                exact: .init(maximumRows: maximumRaw, maximumColumns: maximumRaw, maximumIntegerBits: limits.maximumIntegerBits,
                    maximumWorkspaceBytes: limits.exact.maximumWorkspaceBytes, maximumResultBytes: limits.exact.maximumRetainedBytes),
                root: .init(maximumDimension: k, maximumJacobianNonzeros: limits.maximumTriplets,
                    maximumPreconditionerNonzeros: limits.maximumPreconditionerNonzeros,
                    maximumWorkspaceBytes: limits.root.maximumWorkspaceBytes, maximumResultBytes: limits.root.maximumRetainedBytes))
            // Logical result and bridge payload, excluding caller-owned request buffers and shared snapshot bytes.
            let bridgeBytes = try A.multiply(A.multiply(m, 2), MemoryLayout<NativePrescribedVoltageSource>.stride)
            let ownBytes = try A.add(MemoryLayout<NativePrescribedVoltageFlow.Payload>.stride,
                A.add(bridgeBytes, A.add(A.multiply(m, MemoryLayout<NativePrescribedVoltageFlowSourceScope>.stride),
                    A.add(A.multiply(foreign, MemoryLayout<NativePrescribedVoltageFlowModelScope>.stride),
                        A.add(A.multiply(l, MemoryLayout<E>.stride), A.multiply(A.multiply(l, 2), MemoryLayout<CompensatedValue>.stride))))))
            guard ownBytes <= limits.result.maximumRetainedBytes else { throw Failure.capacityExceeded }
            let fieldBytes = try A.add(A.multiply(l, MemoryLayout<E>.stride), MemoryLayout<[E]>.stride)
            guard fieldBytes <= limits.result.maximumWorkspaceBytes else { throw Failure.capacityExceeded }
            let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(ownBytes))
            let scratchLease = try control.reserveStorage(byteCount: fieldBytes)
            defer { withExtendedLifetime(scratchLease) {} }
            // The bridge buffers are admitted BEFORE construction, even though Values later shares their backing.
            try tick(A.add(A.multiply(m, 3), A.add(foreign, A.multiply(l, 4))))
            var initialSources: [NativePrescribedVoltageSource] = [], windowSources = initialSources
            var sources: [NativePrescribedVoltageFlowSourceScope] = []
            initialSources.reserveCapacity(m); windowSources.reserveCapacity(m); sources.reserveCapacity(m)
            for index in request.sources.indices {
                try tick()
                let input = request.sources[index]
                guard devices.indices.contains(input.deviceIndex), index == 0 || request.sources[index - 1].deviceIndex < input.deviceIndex,
                      input.zeroVoltage.isFinite, input.oneVoltage.isFinite, input.timeOrigin.isFinite,
                      input.timeScale.isFinite, input.timeScale > 0,
                      finite(input.initialNormalized), finite(input.normalized), finite(input.normalizedDerivativePerSecond),
                      input.initialNormalized.lowerBound >= input.normalized.lowerBound,
                      input.initialNormalized.upperBound <= input.normalized.upperBound,
                      let actual = devices[input.deviceIndex] as? BoundVoltageSource else { throw Failure.invalidInput }
                let fact = try actual.independentVoltageSourceFact()
                try fact.validateJoin(variableMap: record.plan.topology.variableMap)
                let derivative = try A.hull(input.normalizedDerivativePerSecond.lowerBound, input.normalizedDerivativePerSecond.upperBound)
                try tick(3)
                let converted = try derivative.multiplied(by: E(center: .init(high: input.timeScale)))
                let convertedBounds = try A.bounds(converted)
                let lo = convertedBounds.0.bounds.lower, hi = convertedBounds.1.bounds.upper
                guard lo.isFinite, hi.isFinite else { throw NumericalStateError.arithmeticOverflow }
                let slope = lo...hi
                initialSources.append(.init(deviceIndex: input.deviceIndex, zeroVoltage: input.zeroVoltage, oneVoltage: input.oneVoltage,
                    timeOrigin: input.timeOrigin, timeScale: input.timeScale, normalized: input.initialNormalized,
                    leftSlope: slope, rightSlope: slope))
                windowSources.append(.init(deviceIndex: input.deviceIndex, zeroVoltage: input.zeroVoltage, oneVoltage: input.oneVoltage,
                    timeOrigin: input.timeOrigin, timeScale: input.timeScale, normalized: input.normalized,
                    leftSlope: slope, rightSlope: slope))
                sources.append(.init(deviceIndex: input.deviceIndex,
                    fact: NativeVoltageSourceFact(fact, preparation: record, storage: lease), assumptions: input, internalNormalizedSlope: slope))
            }
            try tick(3)
            let end = try E(center: request.startTime).adding(E(center: request.duration))
            let endBounds = try A.bounds(end)
            let initialContext = try OSDIPrecisionContext(mode: .transient, timeHigh: request.startTime.high, timeLow: request.startTime.low)
            let upperContext = try OSDIPrecisionContext(mode: .transient, timeHigh: endBounds.1.high, timeLow: endBounds.1.low)
            let initialDomain = NativeGlobalChargeDomain(lower: request.originalLower, upper: request.originalUpper,
                lowerContext: initialContext, upperContext: initialContext)
            let windowDomain = NativeGlobalChargeDomain(lower: request.originalLower, upper: request.originalUpper,
                lowerContext: initialContext, upperContext: upperContext)
            let initialValues = try await NativePrescribedVoltageValues.enclose(record: record, devices: devices,
                originalDomain: initialDomain, sources: initialSources, reducedCoordinates: request.initial.coordinates,
                capture: capture, limits: valuesLimits, cancellation: cancellation)
            try tick(0); phase = .initialRoot
            let initialRoot = try await NativePrescribedVoltageInitialRoot.certify(record: record, devices: devices,
                values: initialValues, algebraicRows: request.algebraicRows, dynamicInitialCoordinates: request.dynamicInitialCoordinates,
                center: request.initial.center, inverse: request.initial.inverse, inverseValues: request.initial.inverseValues,
                capture: capture, range: range, limits: chartLimits, cancellation: cancellation)
            try tick(0)
            let initial = try initialRoot.initialPayload(record: record)
            guard initial.dynamic.count == l else { throw Failure.invalidBinding }
            var chargeLower: [CompensatedValue] = [], chargeUpper = chargeLower
            var chartCharge: [E] = []
            chargeLower.reserveCapacity(l); chargeUpper.reserveCapacity(l); chartCharge.reserveCapacity(l)
            for value in request.chargeBox {
                try tick(4)
                let bounds = try A.bounds(value)
                guard A.ordered(bounds.0, bounds.1) else { throw Failure.invalidInput }
                chargeLower.append(bounds.0); chargeUpper.append(bounds.1)
                chartCharge.append(try hull(bounds.0, bounds.1))
            }
            phase = .windowValues
            let windowValues = try await NativePrescribedVoltageValues.enclose(record: record, devices: devices,
                originalDomain: windowDomain, sources: windowSources, reducedCoordinates: request.window.coordinates,
                capture: capture, limits: valuesLimits, cancellation: cancellation)
            try tick(0); phase = .windowChart
            let chart = try await NativePrescribedVoltageChart.certify(record: record, devices: devices,
                values: windowValues, algebraicRows: request.algebraicRows, chargeParameters: chartCharge,
                center: request.window.center, inverse: request.window.inverse, inverseValues: request.window.inverseValues,
                capture: capture, range: range, limits: chartLimits, cancellation: cancellation)
            try tick(0); phase = .branchJoin
            let window = try chart.evolutionPayload(record: record)
            let initialSource = try initial.values.reconstructionPayload(record: record)
            let windowSource = try window.values.reconstructionPayload(record: record)
            guard initial.dynamic == window.dynamic, initial.algebraic == window.algebraic,
                  window.checkedLower.count == k, initial.checkedLower.count == k,
                  initialSource.captures.count == foreign, windowSource.captures.count == foreign,
                  initialSource.voltages.count == m, windowSource.voltages.count == m else { throw Failure.invalidBinding }
            for row in 0..<k {
                try tick(2)
                guard A.ordered(window.checkedLower[row], initial.checkedLower[row]),
                      A.ordered(initial.checkedUpper[row], window.checkedUpper[row]) else {
                    throw Failure.uncertified(.branchJoin, cause: JoinFailure.initialBoxOutsideWindow)
                }
            }
            for index in 0..<m {
                try tick(2)
                let bounds = try A.bounds(windowSource.voltages[index])
                guard try contained(initialSource.voltages[index], lower: bounds.0, upper: bounds.1) else {
                    throw Failure.uncertified(.branchJoin, cause: JoinFailure.initialSourceOutsideWindow)
                }
            }
            for index in 0..<l {
                try tick(8)
                // hull admitted both exact Picard endpoints by outward distance to its center.
                // Preserve that SAME certified parameter instead of inflating a self-subtraction.
                guard try contained(initial.initialCharge[index], lower: chargeLower[index], upper: chargeUpper[index]),
                      window.chargeParameters[index] == chartCharge[index] else {
                    throw Failure.uncertified(.branchJoin, cause: JoinFailure.chargeDomain)
                }
            }
            var models: [NativePrescribedVoltageFlowModelScope] = []; models.reserveCapacity(foreign)
            var foreignIndex = 0
            for deviceIndex in devices.indices where devices[deviceIndex].instance.osdi != nil {
                try tick()
                let a = initial.identities[foreignIndex].retention, b = window.identities[foreignIndex].retention
                let smooth = window.smooth[foreignIndex]
                guard a.source == b.source, a.workerReference == b.workerReference,
                      a.numericProfile == b.numericProfile, a.options == b.options,
                      a.coverLimits == b.coverLimits, a.identityLimits == b.identityLimits,
                      smooth.source == b.source.source, smooth.workerReference == b.workerReference,
                      smooth.numericProfile == b.numericProfile, smooth.options == b.options,
                      initial.identities[foreignIndex].lowerContext == initialContext,
                      initial.identities[foreignIndex].upperContext == initialContext,
                      window.identities[foreignIndex].lowerContext == initialContext,
                      window.identities[foreignIndex].upperContext == upperContext else { throw Failure.invalidBinding }
                models.append(.init(initialOwner: initialRoot, windowOwner: chart, storage: lease,
                    deviceIndex: deviceIndex, preparation: record.osdiPreparationRecords[foreignIndex],
                    initialBinding: a.source, windowBinding: b.source, smoothBinding: smooth.source,
                    workerReference: b.workerReference, numericProfile: b.numericProfile, options: b.options,
                    coverLimits: b.coverLimits, identityLimits: b.identityLimits, requestedPrecisionBits: limits.precisionBits))
                foreignIndex += 1
            }
            guard foreignIndex == foreign else { throw Failure.invalidBinding }
            phase = .evolution
            let evolution = try NativePrescribedVoltageEvolution.reconstruct(record: record, chart: chart,
                limits: .init(maximumRetainedBytes: limits.evolution.maximumRetainedBytes,
                    maximumWorkspaceBytes: limits.evolution.maximumWorkspaceBytes), cancellation: cancellation)
            try tick(l)
            let zero = try E(center: .zero)
            var field = [E](repeating: zero, count: l)
            for row in 0..<l { try tick(); field[row] = try evolution.chargeRate(at: row) }
            phase = .picard
            let picard = try ValidatedPicardSlab.certify(lower: chargeLower.span, upper: chargeUpper.span,
                initial: initial.initialCharge.span, field: field.span, duration: request.duration,
                lipschitzUpperBound: evolution.chargeStateLipschitzUpperBound,
                limits: .init(maximumDimension: l, maximumResultBytes: limits.result.maximumRetainedBytes),
                control: control, cancellation: cancellation)
            phase = .scope; try tick(0)
            return .init(preparation: record, request: request, sources: sources, models: models,
                initialContext: initialContext, windowLowerContext: initialContext, windowUpperContext: upperContext,
                initialRoot: initialRoot, initial: initial, chart: chart, window: window, evolution: evolution,
                picard: picard, chargeLower: chargeLower, chargeUpper: chargeUpper, lease: lease)
        } catch let error as Failure { throw error }
        catch let error as OSDIConstitutiveCaptureFailure { throw .capture(phase, cause: error) }
        catch let error as OSDISmoothRangeFailure { throw .smooth(phase, cause: error) }
        catch NativeConstitutiveInspection.Failure.cancelled { throw .cancelled }
        catch NativeConstitutivePreparationControl.Failure.cancelled { throw .cancelled }
        catch AnalysisError.cancelled { throw .cancelled }
        catch ValidatedParametricRoot.Failure.uncertified { throw .uncertified(phase, cause: ValidatedParametricRoot.Failure.uncertified) }
        catch let error as ValidatedPicardSlab.Failure { throw .uncertified(phase, cause: error) }
        catch { throw .phase(phase, cause: error) }
    }
    private static func finite(_ value: ClosedRange<Double>) -> Bool { value.lowerBound.isFinite && value.upperBound.isFinite }
    private static func hull(_ lower: CompensatedValue, _ upper: CompensatedValue) throws -> E {
        let lo = try E(center: lower), hi = try E(center: upper), two = try E(center: .init(high: 2))
        let midpoint = try lo.divided(by: two).adding(hi.divided(by: two))
        let center = try E(center: midpoint.center)
        let radius = max(try lo.subtracting(center).absoluteUpperBound, try hi.subtracting(center).absoluteUpperBound)
        return try E(center: center.center, radius: radius)
    }
    private static func contained(_ value: E, lower: CompensatedValue, upper: CompensatedValue) throws -> Bool {
        let lo = try value.subtracting(E(center: lower)), hi = try E(center: upper).subtracting(value)
        let a = try A.bounds(lo).0, b = try A.bounds(hi).0
        return A.ordered(.zero, a) && A.ordered(.zero, b)
    }
}
