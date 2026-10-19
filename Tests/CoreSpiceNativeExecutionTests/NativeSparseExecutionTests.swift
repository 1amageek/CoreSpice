@testable import CoreSpice
import CoreSpiceIO
import Testing

@Suite("Native sparse capacity and identity", .timeLimit(.minutes(1)))
struct NativeSparseExecutionTests {
    private func limits(dimension: Int) -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 64, maximumSolveAttempts: 100,
            maximumNewtonIterations: 1000, maximumSavedScalars: 100_000,
            maximumMatrixDimension: dimension, maximumWorkUnits: 100_000_000,
            maximumBreakpoints: 16)
    }

    @Test func largeDiagonalCircuitAdmitsLocalTopologyAndExecutesUnderSparseCeiling() async throws {
        let dimension = 2048
        let ceiling: UInt64 = 192 * 1024 * 1024
        let resources = SourceBoundaryTestResources(liveLimit: ceiling, temporaryLimit: ceiling,
            workLimit: 1_000_000)
        var saved: DCResult?
        do {
            var netlist = Netlist()
            for index in 0..<dimension {
                let node = "n\(index)"
                try netlist.addInstance(name: "R\(index)", typeName: "resistor", nodes: [node, "0"],
                    parameters: ["r": .real(1000)])
                try netlist.addInstance(name: "I\(index)", typeName: "isource", nodes: [node, "0"],
                    parameters: ["i": .real(-0.001)])
            }
            let owner = try NativeCircuitPreparer().prepare(ir: netlist.build(), registry: .standard(),
                operatingConditions: .nominal,
                limits: .init(maximumDeviceCount: 2 * dimension, maximumMatrixDimension: dimension,
                    maximumAllocationBytes: ceiling), numericalLimits: limits(dimension: dimension), resources: resources)
            #expect(owner.plan.topology.dimension == dimension)
            #expect(owner.plan.matrixStructure.nonZeroCount == dimension)
            #expect(owner.record.compileCapacity < ceiling)
            #expect(UInt64(dimension) * UInt64(dimension) * 256 > ceiling)
            #expect(resources.work(.retainedElements) < 1_000_000)
            let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(run.result.variables.count == dimension)
            #expect(run.result.variables.allSatisfy { abs($0 - 1) < 1e-8 })
            #expect(resources.used(.temporaryBytes) == 0)
            saved = run.result
        }
        #expect(saved?.variables.count == dimension)
        #expect(resources.used(.liveOwnedBytes) > 0)
        saved = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        withExtendedLifetime(saved) {}
    }

    @Test func actualSparseWorkspaceRefusalReleasesCapacityAndFreshRunSucceeds() async throws {
        let resources = SourceBoundaryTestResources()
        var netlist = Netlist()
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"], parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"], parameters: ["i": .real(-0.001)])
        let ir = try netlist.build()
        func prepare() throws -> PreparedNativeCircuit {
            try NativeCircuitPreparer().prepare(ir: ir, registry: .standard(), operatingConditions: .nominal,
                limits: .init(maximumDeviceCount: 8, maximumMatrixDimension: 4,
                    maximumAllocationBytes: 1024 * 1024), numericalLimits: limits(dimension: 4), resources: resources)
        }
        do {
            let owner = try prepare()
            resources.setTemporaryLimit(0)
            do {
                _ = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
                Issue.record("Sparse factorization ignored the execution storage owner")
            } catch SPICENativeExecutionError.resource(let cause) {
                #expect(cause as? SourceBoundaryTestError == .limit(.temporaryBytes))
            }
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        resources.setTemporaryLimit(.max)
        do {
            let run = try await DCAnalysis().run(circuit: prepare(), solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(abs(try #require(run.result.variables.first) - 1) < 1e-8)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func temporarySolverCapacityCoexistsWithOutputAndRefundsAtFinalLease() throws {
        var netlist = Netlist()
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"], parameters: ["r": .real(1000)])
        let resources = SourceBoundaryTestResources()
        do {
            let circuit = try NativeCircuitPreparer().prepare(ir: netlist.build(), registry: .standard(),
                operatingConditions: .nominal,
                limits: .init(maximumDeviceCount: 8, maximumMatrixDimension: 4, maximumAllocationBytes: 1024 * 1024),
                numericalLimits: limits(dimension: 4), resources: resources)
            let owner = try NativeExecutionStorage(preparation: circuit.record, scalars: 2, retainedBytes: 0)
            let live = resources.used(.liveOwnedBytes)
            var lease: (any Sendable)? = try owner.reserveTemporaryBytes(4096)
            var copy = lease
            lease = nil
            #expect(resources.used(.temporaryBytes) == 4096)
            #expect(resources.used(.liveOwnedBytes) == live)
            withExtendedLifetime(copy) {}
            copy = nil
            #expect(resources.used(.temporaryBytes) == 0)
            _ = try owner.reserveTemporaryBytes(4096)
            #expect(resources.used(.temporaryBytes) == 0)
            do {
                _ = try owner.reserveTemporaryBytes(1024 * 1024)
                Issue.record("Workspace ignored preparation and output coexistence")
            } catch SPICENativeExecutionError.resource(let cause) {
                guard case TransientExecutionError.limitExceeded(let resource, _, _) = cause else { throw cause }
                #expect(resource == "allocationBytes")
            }
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
    }
}
