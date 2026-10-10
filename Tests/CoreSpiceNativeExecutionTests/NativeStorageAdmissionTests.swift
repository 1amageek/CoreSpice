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
            let scalarBytes = UInt64(owner.plan.topology.dimension + 1) * 32
            let factBytes = UInt64(owner.plan.ir.instances.count * MemoryLayout<Instance>.stride)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(resources.used(.liveOwnedBytes) == preparationBytes + scalarBytes + factBytes)
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
        let compileBytes = probeResources.used(.liveOwnedBytes)
        let factBytes = UInt64(probe.plan.ir.instances.count * MemoryLayout<Instance>.stride)
        let scalarBytes = UInt64(dimension + 1) * 32
        let bytes = nativeCeiling ? compileBytes * 2 + factBytes + scalarBytes * 3 : 64 * 1024 * 1024
        let resources = SourceBoundaryTestResources(liveLimit: nativeCeiling ? .max : compileBytes + factBytes + scalarBytes * 3)
        let allowedPoints = nativeCeiling ? (bytes - compileBytes - factBytes) / scalarBytes : 3
        var admittedPoints: UInt64 = 1
        while admittedPoints <= allowedPoints / 2 { admittedPoints *= 2 }
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
                    guard case TransientExecutionError.limitExceeded(let resource, _, _) = cause else { throw cause }
                    #expect(resource == "allocationBytes")
                } else { #expect(cause as? SourceBoundaryTestError == .limit(.liveOwnedBytes)) }
            }
        }
        #expect(accepted.withLock { $0 } == Int(admittedPoints) - 1)
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
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

}
