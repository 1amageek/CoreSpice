import CoreSpice
import CoreSpiceIO
import Testing

@Suite("Pure Swift pole-zero native integration", .timeLimit(.minutes(1)))
struct PureSwiftPoleZeroNativeTests {
    private let deck = """
    Pure Swift lead-lag
    V1 in 0 dc 1 ac 1
    R1 in out 1k
    C1 in out 1u
    R2 out 0 1k
    .pz in 0 out 0 vol pz
    .end
    """

    private let limits = SPICENativeExecutionLimits(maximumDeviceCount: 100,
        maximumMatrixDimension: 32, maximumAllocationBytes: 16 * 1024 * 1024)

    private func check(_ result: PoleZeroResult) throws {
        // H(s) = 0.5 * (1 + s/1000) / (1 + s/2000).
        try #require(result.poles.count == 1 && result.zeros.count == 1)
        #expect(abs(result.poles[0].real + 2000) < 1e-6)
        #expect(abs(result.zeros[0].real + 1000) < 1e-6)
        #expect(abs(result.poles[0].imag) < 1e-9)
        #expect(abs(result.zeros[0].imag) < 1e-9)
        #expect(abs(result.dcGain - 0.5) < 1e-12)
    }

    @Test func publicPreparedAPIComputesFinitePoleNonemptyZeroAndGain() async throws {
        let input = try await PreparedNativeExecutionTests().input(deck)
        let native = SPICENativeSimulation()
        let prepared = try native.prepare(input, limits: limits)
        let output = try await native.execute(prepared, cancellation: .init())
        let result = try #require(output.poleZeroResult)
        try check(result)
        #expect(output.sourceInputIdentity == input.sourceInputIdentity)
        #expect(output.phases.map(\.analysis) == ["pz"])
        #expect(output.waveform.pointCount == 1)
        #expect(output.waveform.variables.map(\.name) == ["pole_0", "zero_0", "dc_gain"])
        let expected = [result.poles[0], result.zeros[0], .init(real: result.dcGain)]
        for (index, value) in expected.enumerated() {
            let actual = try #require(output.waveform.complexValue(variable: index, point: 0))
            #expect(actual.real.bitPattern == value.real.bitPattern)
            #expect(actual.imag.bitPattern == value.imag.bitPattern)
        }
    }

    private func circuit(_ input: PreparedSPICESimulation,
                         resources: SourceBoundaryTestResources) throws -> PreparedNativeCircuit {
        try NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: limits,
            numericalLimits: input.configuration.numericalLimits, resources: resources)
    }

    private struct CancelAfterOperatingPoint: AnalysisObserver {
        let cancellation: CancellationToken
        func onEvent(_ event: AnalysisEvent) {
            if case .analysisFinished(let info) = event, info.type == .dc, info.status == .completed {
                cancellation.cancel()
            }
        }
    }

    private struct RefuseExtractionAfterOperatingPoint: AnalysisObserver {
        let resources: SourceBoundaryTestResources
        func onEvent(_ event: AnalysisEvent) {
            if case .analysisFinished(let info) = event, info.type == .dc, info.status == .completed {
                resources.setTemporaryLimit(0)
            }
        }
    }

    private func checkRefund(_ resources: SourceBoundaryTestResources) {
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func extractionQuotaAndCancellationRefundBeforeFreshRetryRetainsResultLease() async throws {
        let input = try await PreparedNativeExecutionTests().input(deck)
        let resources = SourceBoundaryTestResources()
        do {
            let owner = try circuit(input, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let observer = EventDispatcher(observers: [RefuseExtractionAfterOperatingPoint(resources: resources)])
            do {
                _ = try await PoleZeroAnalysis(outputNode: out, inputSourceName: "v1")
                    .run(circuit: owner, solver: SparseLUSolver(), observer: observer, cancellation: .init())
                Issue.record("Pole-zero extraction ignored its temporary storage limit")
            } catch SPICENativeExecutionError.resource(let cause) {
                guard case SourceBoundaryTestError.limit(.temporaryBytes) = cause else { throw cause }
            }
        }
        checkRefund(resources)
        resources.setTemporaryLimit(.max)

        do {
            let owner = try circuit(input, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let cancellation = CancellationToken()
            let observer = EventDispatcher(observers: [CancelAfterOperatingPoint(cancellation: cancellation)])
            do {
                _ = try await PoleZeroAnalysis(outputNode: out, inputSourceName: "v1")
                    .run(circuit: owner, solver: SparseLUSolver(), observer: observer, cancellation: cancellation)
                Issue.record("Pole-zero analysis completed after cancellation of its actual DC child")
            } catch SPICENativeExecutionError.cancelled {
                #expect(cancellation.isCancelled)
            }
        }
        checkRefund(resources)

        var retained: PoleZeroResult?
        do {
            let owner = try circuit(input, resources: resources)
            let out = try #require(owner.plan.ir.nodeNames.first { $0.value == "out" }?.key)
            let run = try await PoleZeroAnalysis(outputNode: out, inputSourceName: "v1")
                .run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
            try check(run.result)
            retained = run.result
        }
        #expect(resources.used(.liveOwnedBytes) > 0)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.peakTemporaryBytes > 0)
        try check(try #require(retained))
        withExtendedLifetime(retained) {}
        retained = nil
        checkRefund(resources)
    }
}
