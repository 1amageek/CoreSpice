import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import CoreSpiceParsedIR
import Foundation
import OSDIContracts
import OSDIRuntime
import Testing
import CoreSpice

@Suite("Actual SDK prescribed-flow voltage observations", .timeLimit(.minutes(2)))
struct NativePrescribedVoltageFlowObservationOSDITests {
    private typealias Pair = NativePrescribedVoltageFlowVoltagePair
    private typealias Limits = NativePrescribedVoltageFlowObservationLimits
    private typealias Observations = NativePrescribedVoltageFlowVoltageObservations
    private let base = NativePrescribedVoltageFlowTests()

    private func limits() -> Limits {
        .init(maximumPairCount: 16, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576)
    }

    private func prepare(_ fixture: NativeGlobalChargeOSDIFixture,
        resources: NativePrescribedVoltageFlowTests.Resources) async throws -> PreparedNativeCircuit {
        let instances: [Instance] = try [
            .init(name: "Vp", typeName: "vsource", nodes: [base.p, .ground], parameters: ["v": .real(0)], ownedBranches: [base.branch]),
            fixture.instance("NQ", nodes: [base.d, .ground], capacitance: 2),
            .init(name: "Rx", typeName: "resistor", nodes: [base.x, base.p], parameters: ["r": .real(4)]),
            .init(name: "Rd", typeName: "resistor", nodes: [base.d, base.p], parameters: ["r": .real(2)]),
            fixture.instance("Nalias", nodes: [base.x, base.x])]
        let runtime = try SPICEOSDIRuntimeInputs(provider: fixture.provider,
            loadLimits: .init(maximumDescriptors: 4, maximumMetadataBytes: 1_048_576, maximumStorageBytes: 1_048_576),
            evaluationLimits: .init(maximumWorkspaceBytes: 1_048_576, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536), maximumInstanceCount: 2,
            maximumAdapterBytes: 16_777_216,
            tolerances: .init(temperatureAbsoluteKelvin: 1e-6, thermalResidualAbsoluteWatts: 1e-12))
        let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
        let snapshot = NativeConstitutivePreparationInputs(preparer: factory,
            semanticProfile: fixture.snapshot.semanticProfile, options: fixture.snapshot.options)
        let preparer: any NativeConstitutiveCircuitPreparing = NativeCircuitPreparer()
        return try await preparer.prepare(
            ir: .init(nodes: [.ground, base.p, base.d, base.x], branches: [base.branch], instances: instances),
            registry: .standard(), operatingConditions: .init(temperatureKelvin: 300.15), limits: fixture.nativeLimits,
            numericalLimits: fixture.numerical, resources: resources, osdi: runtime, constitutive: snapshot, cancellation: .init())
    }

    private func flow(_ owner: borrowing PreparedNativeCircuit, fixture: NativeGlobalChargeOSDIFixture,
        ramp: Bool = false) async throws -> NativePrescribedVoltageFlow {
        let factory = OSDINativePrecisionSessionPreparer(stagingParentDirectory: fixture.directory)
        let original = fixture.capture
        let capture = OSDIConstitutiveCaptureInputs(preparer: factory, worker: original.worker,
            source: original.source, numericProfile: original.numericProfile, options: original.options,
            coverLimits: original.coverLimits, limits: original.limits)
        let range = OSDISmoothRangeCaptureInputs(preparer: factory, worker: original.worker,
            source: original.source, numericProfile: original.numericProfile, options: original.options)
        let source = ramp ? NativePrescribedVoltageFlowSource(deviceIndex: 0, zeroVoltage: 2, oneVoltage: 0,
            timeOrigin: 0, timeScale: 4, initialNormalized: 0.5...0.5, normalized: 0.484375...0.5,
            normalizedDerivativePerSecond: -0.125 ... -0.125) : base.source()
        let originalRequest = try base.request(source: source)
        // Keep the whole initial box inside the window and make C*dV/dt distinct from dV/dt.
        let request = NativePrescribedVoltageFlowRequest(originalLower: try [0.95, 0.35, 0.85, -10].map { try .init(high: $0) },
            originalUpper: try [1.05, 0.65, 1.15, 10].map { try .init(high: $0) }, startTime: originalRequest.startTime, duration: originalRequest.duration,
            sources: originalRequest.sources, algebraicRows: originalRequest.algebraicRows,
            dynamicInitialCoordinates: try [base.e(0.499, 0.501)],
            initial: try base.proposal([base.e(0.49, 0.51), base.e(0.99, 1.01)], initial: true),
            chargeBox: try [base.e(0.9, 1.15)],
            window: try base.proposal([base.e(0.4, 0.6), base.e(0.9, 1.1)], initial: false))
        return try await owner.certifyPrescribedVoltageFlow(request: request, capture: capture, range: range,
            limits: base.limits(), cancellation: .init())
    }

    @Test(arguments: [false, true])
    func actualLinearChargeAndAliasedTopologyKeepVoltageOrientationAndPhysicalSIRate(ramp: Bool) async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try await prepare(fixture, resources: resources)
            do {
                let actual = try await flow(owner, fixture: fixture, ramp: ramp)
                actual.withScope { scope in
                    let alias = scope.models[1].preparation.rawNodeGlobalRows
                    #expect(alias.count == 2 && alias[0] == alias[1])
                }
                let pairs: [Pair] = [.init(positive: base.p, reference: .ground),
                    .init(positive: base.d, reference: .ground), .init(positive: .ground, reference: base.d),
                    .init(positive: base.x, reference: base.p), .init(positive: base.x, reference: base.x),
                    .init(positive: .ground, reference: .ground)]
                let observed = try actual.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                #expect(observed.flow === actual && observed.count == pairs.count)
                let source = try observed.observation(at: 0), dynamic = try observed.observation(at: 1)
                let reverse = try observed.observation(at: 2), alias = try observed.observation(at: 3)
                base.contains(source.initialVoltage, 1)
                base.contains(source.windowVoltage, ramp ? 1.03125 : 1)
                base.contains(source.almostEverywhereRate, ramp ? 0.25 : 0)
                #expect(source.almostEverywhereRate.radius < 1e-12)
                base.contains(dynamic.initialVoltage, 0.5)
                // Independent R=2, C=2 equation: Vd'=(Vp-Vd)/4, not Qd'=(Vp-Vd)/2.
                base.contains(dynamic.almostEverywhereRate, 0.125)
                base.contains(reverse.almostEverywhereRate, -0.125)
                #expect(dynamic.almostEverywhereRate.absoluteUpperBound < 0.2)
                #expect(reverse.initialVoltage == (try dynamic.initialVoltage.negated()))
                #expect(reverse.windowVoltage == (try dynamic.windowVoltage.negated()))
                #expect(reverse.almostEverywhereRate == (try dynamic.almostEverywhereRate.negated()))
                let h = actual.duration.high
                let endpoint = ramp ? 0.25 * h + 0.5 * exp(-h / 4) : 1 - 0.5 * exp(-h / 4)
                base.contains(dynamic.windowVoltage, endpoint)
                base.contains(alias.initialVoltage, 0); base.contains(alias.windowVoltage, 0)
                base.contains(alias.almostEverywhereRate, 0)
                let zero = try CompensatedEnclosure(center: .zero)
                for index in 4..<6 {
                    let row = try observed.observation(at: index)
                    #expect(row.pair == pairs[index])
                    #expect(row.initialVoltage == zero && row.windowVoltage == zero && row.almostEverywhereRate == zero)
                }
                let reservations = resources.reservations, work = resources.work
                for _ in 0..<32 {
                    observed.withObservations { rows in
                        let count = rows.count, first = rows[0].pair, last = rows[5].pair
                        #expect(count == pairs.count && first == pairs[0] && last == pairs[5])
                    }
                }
                #expect(resources.reservations == reservations && resources.work == work)
            } catch { try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }

    @Test func actualOwnerSurvivesObservationRefusalsAndCopiedResultsRetainExactlyThatFlow() async throws {
        let fixture = try NativeGlobalChargeOSDIFixture(), resources = NativePrescribedVoltageFlowTests.Resources()
        do {
            let owner = try await prepare(fixture, resources: resources)
            do {
                let preparationBytes = resources.live + resources.temporary
                var actual: NativePrescribedVoltageFlow? = try await flow(owner, fixture: fixture)
                do {
                    let retainedFlow = try #require(actual)
                    let baseline = resources.live + resources.temporary
                    let pairs: [Pair] = [.init(positive: base.d, reference: .ground), .init(positive: base.p, reference: base.d)]
                    let capacities: [Limits] = [
                        .init(maximumPairCount: 1, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1_048_576),
                        .init(maximumPairCount: 16, maximumRetainedBytes: 1, maximumWorkspaceBytes: 1_048_576),
                        .init(maximumPairCount: 16, maximumRetainedBytes: 1_048_576, maximumWorkspaceBytes: 1)]
                    for capacity in capacities {
                        do {
                            _ = try retainedFlow.observeVoltages(pairs: pairs.span, limits: capacity, cancellation: .init())
                            Issue.record("Observation capacity was ignored")
                        } catch NativePrescribedVoltageFlowObservationFailure.capacityExceeded {}
                        #expect(resources.live + resources.temporary == baseline)
                    }
                    let cancelled = CancellationToken(); cancelled.cancel()
                    do {
                        _ = try retainedFlow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: cancelled)
                        Issue.record("Cancelled observation published")
                    } catch NativePrescribedVoltageFlowObservationFailure.cancelled {}
                    #expect(resources.live + resources.temporary == baseline)
                    resources.arm(work: 0)
                    do {
                        _ = try retainedFlow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                        Issue.record("Observation reset its original work owner")
                    } catch NativePrescribedVoltageFlowObservationFailure.operation(let cause) {
                        guard case NativePrescribedVoltageFlowTests.Refusal.work = cause else { throw cause }
                    }
                    resources.arm(deny: true)
                    do {
                        _ = try retainedFlow.observeVoltages(pairs: pairs.span, limits: limits(), cancellation: .init())
                        Issue.record("Observation ignored original storage refusal")
                    } catch NativePrescribedVoltageFlowObservationFailure.operation(let cause) {
                        guard case NativePrescribedVoltageFlowTests.Refusal.storage = cause else { throw cause }
                    }
                    resources.arm()
                    #expect(resources.live + resources.temporary == baseline)
                    let unknown = Node(id: 999)
                    let bad: [Pair] = [.init(positive: unknown, reference: .ground)]
                    do {
                        _ = try retainedFlow.observeVoltages(pairs: bad.span, limits: limits(), cancellation: .init())
                        Issue.record("Unrelated original node acquired an observation")
                    } catch NativePrescribedVoltageFlowObservationFailure.unknownNode(let node) { #expect(node == unknown) }
                    #expect(resources.live + resources.temporary == baseline)
                }
                var first: Observations?
                let pair: [Pair] = [.init(positive: base.d, reference: .ground)]
                do {
                    let retainedFlow = try #require(actual)
                    first = try retainedFlow.observeVoltages(pairs: pair.span, limits: limits(), cancellation: .init())
                    #expect(first?.flow === retainedFlow)
                }
                var copy = first
                first = nil; actual = nil; try owner.close()
                #expect(resources.live + resources.temporary > preparationBytes)
                do {
                    let retained = try #require(copy)
                    #expect(retained.count == 1)
                    base.contains(try retained.observation(at: 0).initialVoltage, 0.5)
                    base.contains(try retained.flow.endpointCharge(at: 0), 2 - exp(-0.125 / 4))
                }
                copy = nil
                #expect(resources.live + resources.temporary == preparationBytes)
            } catch { resources.arm(); try owner.close(); throw error }
            try owner.close()
        } catch { try await fixture.close(); throw error }
        #expect(resources.live == 0 && resources.temporary == 0)
        try await fixture.close()
    }
}
