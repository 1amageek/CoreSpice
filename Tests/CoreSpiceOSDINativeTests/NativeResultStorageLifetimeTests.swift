@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import CoreSpiceExporter
import CoreSpiceExporterCSV
import CoreSpiceWaveform
import Foundation
import OSDIContracts
import Synchronization
import Testing

@Suite("Native numerical result and foreign storage lifetimes", .timeLimit(.minutes(3)))
struct NativeResultStorageLifetimeTests {
    private static let foreignBytes: UInt64 = 24 * 1024 * 1024
    private final class Resources: SPICESourceResourceAccounting {
        private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var liveReservations: [UInt64: Int] = [:] }
        private let state = Mutex(State())
        private let original: SPICESimulationResources
        init() throws {
            original = try .init(maximumLiveBytes: NativeResultStorageLifetimeTests.foreignBytes + 2 * 1024 * 1024,
                maximumTemporaryBytes: 64 * 1024 * 1024, maximumWorkUnits: 1_000_000_000,
                maximumHashedBytes: 64 * 1024 * 1024)
        }
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var foreignReservations: Int { state.withLock { $0.liveReservations[NativeResultStorageLifetimeTests.foreignBytes, default: 0] } }
        func checkCancellation() throws { try original.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try original.charge(kind, units: units) }
        func chargeHashedBytes(_ bytes: UInt64) throws { try original.chargeHashedBytes(bytes) }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            let admitted = try original.reserveStorage(kind: kind, byteCount: byteCount)
            state.withLock {
                if kind == .liveOwnedBytes { $0.live += byteCount; $0.liveReservations[byteCount, default: 0] += 1 }
                else { $0.temporary += byteCount }
            }
            return .init(kind: kind, byteCount: byteCount) { [self, admitted] in
                state.withLock {
                    if kind == .liveOwnedBytes { $0.live -= byteCount; $0.liveReservations[byteCount, default: 0] -= 1 }
                    else { $0.temporary -= byteCount }
                }
                withExtendedLifetime(admitted) {}
            }
        }
    }
    private struct CancelStartedDC: AnalysisObserver {
        let cancellation: CancellationToken
        func onEvent(_ event: AnalysisEvent) {
            if case .analysisStarted(let info) = event, info.type == .dc { cancellation.cancel() }
        }
    }

    @Test func retainedStoredSweepsReleaseForeignCapacityAndStillRoundTripJSONAndCSV() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "linear-current" })
        try #require(point.input.devices.count == 1)
        let input = try await fixture.input(point)
        let resources = try Resources()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        do {
            let first = try await storedSweep(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
            #expect(resources.foreignReservations == 0)
            #expect(resources.live > 0)
            try tracked.expectClosed()
            // This ceiling admits one foreign image, so keeping an old closed image would refuse here.
            let second = try await storedSweep(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
            #expect(resources.foreignReservations == 0)
            #expect(first.stored == second.stored)
            let bytes = try first.stored.withSerialization { try JSONEncoder().encode(first.stored) }
            let restored = try JSONDecoder().decode(SPICENativeStoredDCResult.self, from: bytes)
            #expect(restored == first.stored)
            let coordinates = try #require(first.stored.coordinateBits).map(Double.init(bitPattern:))
            let name = try #require(first.stored.parameterName)
            let results = try first.stored.points.indices.map { try first.stored.result(at: $0) }
            let sweep = SweepResult(parameterName: name, values: coordinates, results: results)
            let waveform = WaveformData.from(sweepResult: sweep, topology: first.topology)
            let path = fixture.directory.appendingPathComponent("stored-sweep.csv")
            let exported = try await CSVExporter().export(waveform, to: .file(path: path.path),
                configuration: .init(precision: 17))
            #expect(exported.success && exported.pointsExported == 2)
            let reloaded = try CSVWaveformReader().read(contentsOfFile: path.path)
            #expect(reloaded.sweepValues.map(\.bitPattern) == coordinates.map(\.bitPattern))
            for point in results.indices {
                for variable in results[point].variables.indices {
                    let display = try #require(reloaded.realValue(variable: variable, point: point))
                    #expect(display.bitPattern == results[point].variables[variable].bitPattern)
                }
                let decoded = try restored.result(at: point)
                #expect(decoded.variables.map(\.bitPattern) == results[point].variables.map(\.bitPattern))
                #expect(decoded.variableLowComponents?.map(\.bitPattern) == results[point].variableLowComponents?.map(\.bitPattern))
            }
            try tracked.expectClosed()
        }
        #expect(tracked.count == 2)
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func valueEvidenceDoesNotReduceTheOriginalNativeAllocationFloor() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "linear-current" })
        let input = try await fixture.input(point)
        let resources = try Resources()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        do {
            let circuit = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
            let floor = circuit.record.compileCapacity
            #expect(floor >= Self.foreignBytes)
            let storage = try NativeExecutionStorage(preparation: circuit.record, scalars: 1, retainedBytes: 0)
            let before = resources.live
            do {
                _ = try storage.reserveMaterializationBytes(fixture.limits.maximumAllocationBytes - floor)
                Issue.record("Value evidence weakened the original native allocation floor")
            } catch SPICENativeExecutionError.resource(let cause) {
                guard case TransientExecutionError.limitExceeded(let resource, let limit, let requested) = cause else { throw cause }
                #expect(resource == "allocationBytes")
                #expect(limit == Int(fixture.limits.maximumAllocationBytes) && requested > limit)
            }
            #expect(resources.live == before && resources.foreignReservations == 1)
            let valid = try storage.reserveMaterializationBytes(1)
            try circuit.close()
            try tracked.expectClosed()
            withExtendedLifetime(valid) {}
        }
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func cancellationAndBusyCleanupKeepTheirActualExecutableAuthority() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "linear-current" })
        let input = try await fixture.input(point)
        let resources = try Resources()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        do {
            let circuit = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
            let token = CancellationToken()
            do {
                _ = try await DCAnalysis(config: input.configuration.options.convergence).run(circuit: circuit,
                    solver: SparseLUSolver(), observer: EventDispatcher(observers: [CancelStartedDC(cancellation: token)]), cancellation: token)
                Issue.record("Cancelled execution published a result")
            } catch SPICENativeExecutionError.cancelled {}
        }
        try tracked.expectClosed()
        #expect(resources.live == 0 && resources.temporary == 0)
        let blocked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider, holdStorage: true)
        defer { blocked.releaseStorage() }
        var pending: SPICEOSDICleanupFailure? = try await busyCleanup(input: input, fixture: fixture,
            point: point, resources: resources, tracked: blocked)
        #expect(resources.foreignReservations == 1)
        do {
            let unexpected = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: blocked)
            try unexpected.close()
            Issue.record("Busy foreign cleanup lost its reservation before retry")
        } catch SPICENativePreparationError.resource(let cause) {
            guard case SPICESimulationResources.ResourceError.storageLimit = cause else { throw cause }
        }
        #expect(blocked.count == 1)
        do {
            let cleanup = try #require(pending)
            do { try cleanup.retryClose(); Issue.record("Busy foreign retry unexpectedly closed") }
            catch OSDIAdapterFailure.runtime(.libraryInUse) {}
            #expect(resources.foreignReservations == 1)
            blocked.releaseStorage()
            try cleanup.retryClose()
            try blocked.expectClosed()
        }
        pending = nil
        #expect(resources.live == 0 && resources.temporary == 0)
        let next = try await storedSweep(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
        #expect(resources.foreignReservations == 0)
        withExtendedLifetime(next) {}
    }

    @Test func actualCMGMetadataRetainsOneSharedLeaseAfterForeignClose() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "cmg-n-selfheat-series-loaded" })
        let input = try await fixture.input(point)
        let resources = try Resources()
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        var retained: NativeCircuitPreparationRecord?
        var retainedBytes: UInt64 = 0
        do {
            let circuit = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
            let record = circuit.record
            let model = try #require(record.osdiPreparationRecords.first)
            let formerCapacity = record.reservations.prefix(2).reduce(UInt64(0)) { $0 + $1.byteCount }
            let parameterArrayBytes = UInt64(model.receipt.resolvedParameters.capacity * MemoryLayout<OSDIResolvedParameter>.stride)
            #expect(parameterArrayBytes > formerCapacity)
            let payload = try NativeOSDIValueEvidence.byteCount(records: record.osdiPreparationRecords, resources: resources)
            #expect(record.reservations.count == 4 && record.reservations[2].byteCount == payload)
            #expect(payload > parameterArrayBytes && payload < 2 * 1024 * 1024)
            let before = resources.live
            let first = try record.valueEvidence()
            let second = try first.valueEvidence()
            retainedBytes = formerCapacity + payload
            #expect(first.osdiLifetime == nil && second.osdiLifetime == nil)
            #expect(first.reservations.count == 3 && second.reservations.count == 3)
            #expect(first.compileCapacity == retainedBytes && second.compileCapacity == retainedBytes)
            #expect(resources.live == before)
            retained = second
            let denied = try SPICESimulationResources(maximumLiveBytes: 1, maximumTemporaryBytes: 1,
                maximumWorkUnits: 1, maximumHashedBytes: 1)
            do {
                _ = try NativeOSDIValueEvidence.byteCount(records: record.osdiPreparationRecords, resources: denied)
                Issue.record("Immutable metadata bypassed the invocation work budget")
            } catch SPICESimulationResources.ResourceError.workLimit {}
            let facts = record.osdiPreparationRecords
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try NativeOSDIValueEvidence.byteCount(records: facts, resources: resources)
                    Issue.record("Cancelled immutable metadata measurement succeeded")
                } catch SPICESimulationResources.ResourceError.cancelled {}
            }
            try await cancelled.value
            try circuit.close()
            try tracked.expectClosed()
        }
        #expect(resources.foreignReservations == 0 && resources.live == retainedBytes)
        do {
            let value = try #require(retained)
            let fact = try #require(value.osdiPreparationRecords.first?.receipt.resolvedParameters.first)
            #expect(!fact.parameter.names.isEmpty)
            let next = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
            try next.close()
            try tracked.expectClosed()
        }
        #expect(resources.foreignReservations == 0 && resources.live == retainedBytes)
        retained = nil
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func coldPrecisionArraysRemainAdmittedAfterHelperClose() async throws {
        let fixture = try await OSDIPrecisionNativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let input = try await fixture.input()
        var retained: NativeCircuitPreparationRecord?
        var programCount = 0
        var setupCount = 0
        var firstProgramByte: UInt8 = 0
        do {
            let circuit = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
                operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
                numericalLimits: input.configuration.numericalLimits, resources: input.resources, osdi: fixture.runtime())
            let precision = try #require(circuit.record.osdiPreparationRecords.first?.transientPrecision)
            let coldBytes = UInt64(precision.program.programBytes.capacity + precision.program.setupBytes.capacity)
            #expect(circuit.record.reservations[2].byteCount >= coldBytes)
            programCount = precision.program.programBytes.count
            setupCount = precision.program.setupBytes.count
            firstProgramByte = try #require(precision.program.programBytes.first)
            retained = try circuit.record.valueEvidence()
            try circuit.close()
        }
        do {
            let value = try #require(retained)
            let precision = try #require(value.osdiPreparationRecords.first?.transientPrecision)
            #expect(value.osdiLifetime == nil && value.reservations.count == 3)
            #expect(precision.program.programBytes.count == programCount)
            #expect(precision.program.programBytes.first == firstProgramByte)
            #expect(precision.program.setupBytes.count == setupCount && setupCount > 0)
        }
        retained = nil
    }

    private func prepare(input: PreparedSPICESimulation, fixture: OSDINativeFixture, point: OSDIDCManifest.Case,
                         resources: Resources, tracked: OSDINativeExecutionTests.TrackingProvider) async throws -> PreparedNativeCircuit {
        try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: input.configuration.numericalLimits, resources: resources,
            osdi: fixture.runtime(point, provider: tracked))
    }
    private func storedSweep(input: PreparedSPICESimulation, fixture: OSDINativeFixture, point: OSDIDCManifest.Case,
                             resources: Resources, tracked: OSDINativeExecutionTests.TrackingProvider)
        async throws -> (stored: SPICENativeStoredDCResult, topology: CircuitTopology) {
        let circuit = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
        let topology = circuit.plan.topology.circuitTopology
        let run = try await DCAnalysis(config: input.configuration.options.convergence).runSweep(circuit: circuit,
            source: "VREF", values: [0, 1], solver: SparseLUSolver(), observer: nil, cancellation: .init())
        return (try SPICENativeStoredDCResult(sweep: run.result), topology)
    }
    private func busyCleanup(input: PreparedSPICESimulation, fixture: OSDINativeFixture, point: OSDIDCManifest.Case,
                             resources: Resources, tracked: OSDINativeExecutionTests.TrackingProvider) async throws -> SPICEOSDICleanupFailure {
        let circuit = try await prepare(input: input, fixture: fixture, point: point, resources: resources, tracked: tracked)
        do {
            _ = try await DCAnalysis(config: input.configuration.options.convergence).run(circuit: circuit,
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("Busy cleanup published a completed result")
            throw SPICENativeExecutionError.invalidOutput
        } catch SPICENativeExecutionError.osdiCleanup(let pending) { return pending }
    }
}
