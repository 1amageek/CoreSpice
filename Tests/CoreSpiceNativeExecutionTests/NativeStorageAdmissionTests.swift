@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceWaveform
import Testing
import Synchronization

extension PreparedNativeExecutionTests {
    private func storageLimits(saved: Int = 20_000_000) -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 5000, maximumSolveAttempts: 10_000,
            maximumNewtonIterations: 50_000, maximumSavedScalars: saved,
            maximumMatrixDimension: 32, maximumWorkUnits: 100_000_000, maximumBreakpoints: 1000)
    }
    private func storageCircuit(_ input: PreparedSPICESimulation, limits: TransientExecutionLimits,
                                bytes: UInt64 = 64 * 1024 * 1024,
                                resources: SourceBoundaryTestResources) throws -> PreparedNativeCircuit {
        try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(),
            limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: bytes),
            numericalLimits: limits, resources: resources)
    }

    @Test func generousScalarCeilingDoesNotRequestOutputAllocation() async throws {
        let input = try await input("Permissive ceiling\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources(liveLimit: 1_000_000)
        do {
            let owner = try storageCircuit(input, limits: storageLimits(), resources: resources)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(run.result.variables.contains { abs($0 - 1) < 1e-8 })
            #expect(resources.used(.liveOwnedBytes) < 1_000_000)
            withExtendedLifetime(run) {}
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func preparedCapacityIsChargedOnlyOnceAtExecution() async throws {
        let input = try await input("One preparation lease\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        var result: DCResult?
        var preparationBytes: UInt64 = 0
        do {
            let owner = try storageCircuit(input, limits: storageLimits(saved: 64), resources: resources)
            preparationBytes = resources.used(.liveOwnedBytes)
            #expect(owner.record.reservations.count == 2)
            let scalarBytes = UInt64(owner.plan.topology.dimension + 1) * 32
            let executionHeaderBytes = UInt64(MemoryLayout<UInt64>.stride)
            let factBytes = UInt64(owner.plan.ir.instances.count * MemoryLayout<Instance>.stride)
            let dcBytes = try NativeCircuitExecution.dcOutputCapacity(owner.record, points: 1) + NativeCircuitExecution.dcWorkingCapacity(owner.record)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(resources.used(.liveOwnedBytes) == preparationBytes + executionHeaderBytes + scalarBytes + factBytes + dcBytes)
            result = run.result
        }
        #expect(resources.used(.liveOwnedBytes) > preparationBytes)
        withExtendedLifetime(result) {}
        result = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test(arguments: [false, true])
    func growingTraceRefusesBeforeAcceptedPointPublicationAndReleases(nativeCeiling: Bool) async throws {
        let input = try await input("Growing trace\nV1 out 0 1\nR1 out 0 1k\n.tran 1u 1m\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else { Issue.record("Missing transient"); return }
        let limits = storageLimits()
        config.executionLimits = limits
        let probeResources = SourceBoundaryTestResources()
        let probe = try storageCircuit(input, limits: storageLimits(saved: 64), resources: probeResources)
        let dimension = probe.plan.topology.dimension
        let compileBytes = probe.record.compileCapacity
        let preparationLiveBytes = probeResources.used(.liveOwnedBytes)
        let factBytes = UInt64(probe.plan.ir.instances.count * MemoryLayout<Instance>.stride)
        // Non-OSDI execution retains one immutable original-allocation-floor scalar.
        let executionHeaderBytes = UInt64(MemoryLayout<UInt64>.stride)
        // Each geometric point slot retains time, the full solution and one audit
        // record. The initial DC vector is retained once; execution scratch and
        // sparse factors participate in the combined native peak ceiling.
        let auditScalars = (MemoryLayout<TransientAcceptedStep>.stride + MemoryLayout<Double>.stride - 1) / MemoryLayout<Double>.stride
        let pointScalars = UInt64(dimension + 1 + auditScalars)
        let operatingPointScalars = UInt64(dimension)
        let dcWorkingBytes = try NativeCircuitExecution.dcWorkingCapacity(probe.record)
        func resultBytes(points: UInt64) -> UInt64 { (points * pointScalars + operatingPointScalars) * 32 }
        var executionTemporaryPeak: UInt64 = 0
        var calibratedPoints = 0
        if nativeCeiling {
            let calibrationResources = SourceBoundaryTestResources()
            do {
                let owner = try storageCircuit(input, limits: limits, resources: calibrationResources)
                calibrationResources.resetTemporaryPeak()
                let run = try await TransientAnalysis(config: config).run(circuit: owner,
                    solver: SparseLUSolver(), observer: nil, cancellation: .init())
                #expect(run.result.timePoints.last == config.stopTime)
                calibratedPoints = run.result.timePoints.count
                executionTemporaryPeak = calibrationResources.peakTemporaryBytes
                withExtendedLifetime(run) {}
            }
            #expect(calibrationResources.used(.liveOwnedBytes) == 0)
            #expect(calibrationResources.used(.temporaryBytes) == 0)
            #expect(calibrationResources.releaseCount == calibrationResources.reservationCount)
        }
        func retainedNativeBytes(points: UInt64) -> UInt64 {
            compileBytes + executionHeaderBytes + factBytes + resultBytes(points: points) + dcWorkingBytes
        }
        var admittedPoints: UInt64 = 4
        // Admit every measured numerical workspace at this point boundary, while
        // the next trace doubling alone exceeds that entire scratch allowance.
        while nativeCeiling && (admittedPoints * pointScalars * 32 <= executionTemporaryPeak ||
            retainedNativeBytes(points: admittedPoints) + executionTemporaryPeak < compileBytes * 2) {
            admittedPoints *= 2
        }
        if nativeCeiling { try #require(Int(admittedPoints) < calibratedPoints) }
        let bytes = nativeCeiling
            ? retainedNativeBytes(points: admittedPoints) + executionTemporaryPeak : 64 * 1024 * 1024
        let liveBoundary = preparationLiveBytes + executionHeaderBytes + factBytes + resultBytes(points: admittedPoints) + dcWorkingBytes
        let resources = SourceBoundaryTestResources(liveLimit: nativeCeiling ? .max : liveBoundary)
        let accepted = Mutex(0)
        do {
            let owner = try storageCircuit(input, limits: limits, bytes: bytes, resources: resources)
            do {
                _ = try await TransientAnalysis(config: config, onStepAccepted: { _, _ in
                    accepted.withLock { $0 += 1 }
                }).run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("Trace growth exceeded the byte ceiling")
            } catch SPICENativeExecutionError.resource(let cause) {
                if nativeCeiling {
                    guard case TransientExecutionError.limitExceeded(let resource, let limit, let requested) = cause else { throw cause }
                    #expect(resource == "allocationBytes")
                    #expect(limit == Int(bytes))
                    #expect(requested > Int(bytes))
                    let nextTraceBytes = retainedNativeBytes(points: admittedPoints * 2)
                    #expect(requested >= Int(nextTraceBytes))
                    #expect(requested <= Int(nextTraceBytes + executionTemporaryPeak))
                } else { #expect(cause as? SourceBoundaryTestError == .limit(.liveOwnedBytes)) }
            }
        }
        #expect(accepted.withLock { $0 } == Int(admittedPoints) - 1)
        #expect(resources.peakLiveBytes == liveBoundary)
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.releaseCount == resources.reservationCount)
    }

    @Test func transientAndFourierUseCompletedCapacityUnderPermissivePolicy() async throws {
        let input = try await input("Actual trace and scratch\nV1 out 0 1\nR1 out 0 1k\n.tran 10u 100u\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else { Issue.record("Missing transient"); return }
        config.executionLimits = storageLimits()
        let resources = SourceBoundaryTestResources(liveLimit: 1_000_000, temporaryLimit: 1_000_000)
        var nested: TransientResult?
        do {
            let owner = try storageCircuit(input, limits: config.requiredExecutionLimits(), resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let run = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 3,
                outputNodes: [out], transientConfig: config).run(circuit: owner,
                    solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(run.result.transientResult.timePoints.last == config.stopTime)
            #expect(run.result.harmonics.values.first?.count == 4)
            #expect(resources.used(.temporaryBytes) == 0)
            nested = run.result.transientResult
        }
        #expect(resources.used(.liveOwnedBytes) > 0)
        withExtendedLifetime(nested) {}
        nested = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }
    private struct CancelFourierAfterTransient: AnalysisObserver {
        let cancellation: CancellationToken

        func onEvent(_ event: AnalysisEvent) {
            if case .analysisFinished(let info) = event,
               info.type == .tran, info.status == .completed {
                cancellation.cancel()
            }
        }
    }

    @Test func fourierCancellationAfterTransientReleasesAllNativeStorage() async throws {
        let input = try await input("Fourier cancelled boundary\nV1 out 0 1\nR1 out 0 1k\n.tran 10u 100u\n.end\n")
        guard case .transient(var config) = input.configuration.analysis else {
            Issue.record("Missing transient"); return
        }
        config.executionLimits = storageLimits()
        let resources = SourceBoundaryTestResources(liveLimit: 1_000_000, temporaryLimit: 1_000_000)
        let cancellation = CancellationToken()
        let buffered = try BufferingObserver(capacity: 10_000)
        let dispatcher = EventDispatcher(observers: [CancelFourierAfterTransient(cancellation: cancellation), buffered])
        do {
            let owner = try storageCircuit(input, limits: config.requiredExecutionLimits(), resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            do {
                _ = try await FourierAnalysis(fundamentalFrequency: 20_000, harmonicCount: 3,
                    outputNodes: [out], transientConfig: config).run(circuit: owner,
                        solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                Issue.record("Cancelled Fourier published a Native result")
            } catch SPICENativeExecutionError.cancelled {}
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        let terminal = buffered.events.compactMap { event -> AnalysisFinishedInfo? in
            if case .analysisFinished(let info) = event, info.type == .fourier { return info }
            return nil
        }
        #expect(terminal.count == 1)
        #expect(terminal.first?.status == .cancelled)
    }

    @Test func storageFailurePoisonsTheOwnerAndLeavesNoPendingLease() async throws {
        let input = try await input("Failed capacity owner\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        do {
            let circuit = try storageCircuit(input, limits: storageLimits(), resources: resources)
            let storage = try NativeExecutionStorage(preparation: circuit.record, scalars: 1, retainedBytes: 0)
            let baseline = resources.used(.liveOwnedBytes)
            do {
                try storage.reserveResultScalars(Int.max)
                Issue.record("Capacity arithmetic overflow was admitted")
            } catch SPICENativeExecutionError.resource(let cause) {
                guard case TransientExecutionError.arithmeticOverflow = cause else { throw cause }
            }
            #expect(resources.used(.liveOwnedBytes) == baseline)
            #expect(throws: (any Error).self) { try storage.reserveResultScalars(1) }
            #expect(throws: (any Error).self) { _ = try storage.reserveTemporaryBytes(1) }
            #expect(resources.used(.liveOwnedBytes) == baseline)
            #expect(resources.used(.temporaryBytes) == 0)
            withExtendedLifetime(storage) {}
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func groundReferenceDoesNotConsumeMatrixDimensionOrStorage() async throws {
        let input = try await input("Exact MNA dimension\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n")
        var limits = storageLimits()
        limits.maximumMatrixDimension = 2
        let resources = SourceBoundaryTestResources()
        do {
            let owner = try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(),
                limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 2, maximumAllocationBytes: 64 * 1024 * 1024),
                numericalLimits: limits, resources: resources)
            #expect(owner.plan.topology.dimension == 2)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(run.result.variables.count == 2)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func projectedWaveformRetainsTheNativeLeaseWithoutPhaseCollector() async throws {
        let input = try await input("Waveform storage lifetime\nV1 out 0 1\nR1 out 0 1k\n.save v(out)\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        var waveform: WaveformData?
        do {
            let circuit = try storageCircuit(input, limits: storageLimits(), resources: resources)
            let topology = circuit.plan.topology.circuitTopology
            let run = try await DCAnalysis().run(circuit: circuit, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            waveform = try SPICEOutputProjector.project(WaveformData.from(dcResult: run.result, topology: topology),
                controls: input.netlist.controls)
        }
        #expect(waveform?.variableCount == 1)
        #expect(resources.used(.liveOwnedBytes) > 0)
        var copied = waveform
        waveform = nil
        #expect(resources.used(.liveOwnedBytes) > 0)
        withExtendedLifetime(copied) {}
        copied = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func retainedDCMaterializationsAdmitIndependentlyAndRefundBeforeRetry() async throws {
        let input = try await input("Materialization leases\nV1 out 0 .5\nR1 out 0 1k\n.op\n.end\n")
        let resources = SourceBoundaryTestResources()
        do {
            let owner = try storageCircuit(input, limits: storageLimits(), bytes: 500_000, resources: resources)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            let stored = try SPICENativeStoredDCResult(operatingPoint: run.result)
            let baseline = resources.used(.liveOwnedBytes)
            var retained: [DCResult] = []
            var refused = false
            for _ in 0..<4096 {
                do { retained.append(try stored.result(at: 0)) }
                catch SPICENativeExecutionError.resource(let cause) {
                    guard case TransientExecutionError.limitExceeded(let resource, _, _) = cause else { throw cause }
                    #expect(resource == "allocationBytes")
                    refused = true
                    break
                }
            }
            #expect(refused && !retained.isEmpty)
            let full = resources.used(.liveOwnedBytes)
            retained.removeLast()
            #expect(resources.used(.liveOwnedBytes) < full)
            retained.append(try stored.result(at: 0))
            #expect(resources.used(.liveOwnedBytes) == full)
            retained.removeAll()
            #expect(resources.used(.liveOwnedBytes) == baseline)
            var copies: [SPICENativeStoredDCResult] = []
            var constructorsRefused = false
            for _ in 0..<4096 {
                do { copies.append(try .init(operatingPoint: run.result)) }
                catch SPICENativeExecutionError.resource { constructorsRefused = true; break }
            }
            #expect(constructorsRefused && !copies.isEmpty)
            let copiesFull = resources.used(.liveOwnedBytes)
            copies.removeLast()
            copies.append(try .init(operatingPoint: run.result))
            #expect(resources.used(.liveOwnedBytes) == copiesFull)
            copies.removeAll()
            #expect(resources.used(.liveOwnedBytes) == baseline)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        for _ in 0..<32 {
                            let restored = try stored.result(at: 0)
                            #expect(restored.variableLowComponents != nil)
                            #expect(restored.variables == run.result.variables)
                        }
                    }
                }
                try await group.waitForAll()
            }
            #expect(resources.used(.liveOwnedBytes) == baseline)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

}
