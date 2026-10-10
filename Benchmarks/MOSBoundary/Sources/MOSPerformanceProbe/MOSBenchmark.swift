import CoreSpice
import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Foundation
import NativeHeapMetrics

@main
struct MOSBenchmark {
    private enum AllocationFailure: Error {
        case missingInterposer
        case calibration(Int32)
        case snapshot(Int32)
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, ["cold", "reuse"].contains(arguments[1]),
              let repetitions = Int(arguments[3]), (1...20).contains(repetitions),
              arguments[1] != "cold" || repetitions == 1 else { throw BenchmarkFailure.invalidArguments }
        let allocationProbe = ProcessInfo.processInfo.environment["MOS_ALLOCATION_PROBE"] == "1"
        var calibration: [String: UInt64]?
        if allocationProbe {
            guard mos_native_allocation_initialize() == 0 else { throw AllocationFailure.missingInterposer }
            let before = mos_native_allocation_capture(0)
            let status = mos_native_allocation_calibrate()
            guard status == 0 else { throw AllocationFailure.calibration(status) }
            let after = mos_native_allocation_capture(0)
            guard before.status == 0, after.status == 0 else { throw AllocationFailure.snapshot(after.status) }
            calibration = allocationDelta(before, after)
        }
        let policy = try BenchmarkPolicy(), source = try policy.source(release: arguments[2])
        let resources = try MeasuredResources()
        let compileMeter = ResolutionMeter(resources: resources)
        let envelope = try NetlistLowering.resourceEnvelope(limits: policy.resolution)
        let retained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: envelope.maximumRetainedBytes)
        let heapBeforeSetup = heap()
        let allocationBeforeCompile = try allocationCapture(enabled: allocationProbe, resume: 1)
        let originalStart = ContinuousClock.now
        let parsed = try await SPICEParser().parse(source: source).get()
        let afterParse = ContinuousClock.now
        let compiled: CompiledNetlist
        do {
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: envelope.maximumTemporaryBytes)
            compiled = try NetlistLowering.compile(parsed, limits: policy.resolution, control: compileMeter)
            withExtendedLifetime(scratch) {}
        }
        let afterCompile = ContinuousClock.now
        let allocationAfterCompile = try allocationCapture(enabled: allocationProbe, resume: 0)
        let compileCounters = compileMeter.snapshot
        var rows: [[String: Any]] = []
        for index in 0..<repetitions {
            let start = arguments[1] == "cold" ? originalStart : ContinuousClock.now
            rows.append(try await sample(compiled: compiled, policy: policy, resources: resources,
                start: start, mode: arguments[1], ordinal: index, allocationProbe: allocationProbe))
        }
        var output: [String: Any] = [
            "schema": "CoreSpice.S5.CPUPerformance.v1", "mode": arguments[1], "release": arguments[2],
            "profile": policy.profile.rawValue, "seed": policy.seed, "source": source,
            "parseSeconds": seconds(originalStart, afterParse),
            "compileSeconds": seconds(afterParse, afterCompile),
            "parseAndCompileSeconds": seconds(originalStart, afterCompile),
            "compileResolutionWork": compileCounters, "heapBeforeSetup": heapBeforeSetup,
            "resourceEnvelope": ["maximumRetainedBytes": envelope.maximumRetainedBytes,
                "maximumTemporaryBytes": envelope.maximumTemporaryBytes,
                "maximumSimultaneousBytes": envelope.maximumSimultaneousBytes],
            "samples": rows, "resourceAfterSamples": try object(resources.snapshot),
            "measurementAvailability": [
                "rawAllocationCalls": NSNull(), "rawAllocatedByteTotal": NSNull(), "copyAPI": "Calibrated memcpy/memmove/bcopy alias-family entries and byte arguments, including verified fortified forwarding; compiler-inlined copies and private loops are excluded",
                "globalKernelCallEvents": NSNull(),
                "heap": "Darwin malloc_zone_statistics capacities and process rusage highwater, not cumulative allocation counts",
                "coldSetup": "Published preparation receipt coldSetupCount plus unchanged preparation work during analysis; not an independent global hook",
                "resolution": "Actual MOSResolutionControlling work charges; candidate work units also include duplicate checks",
                "sourceIO": "Original source is a retained deterministic string; file read time is excluded",
                "cold": "Fresh process per cold sample; process startup wall time is recorded separately by the runner",
                "reuse": "One immutable compiled snapshot per process; each sample has a new session and new native owner",
                "allocationTrace": "Optional separate xctrace Allocations run; its timing is excluded from comparison"
            ]
        ]
        if let before = allocationBeforeCompile, let after = allocationAfterCompile {
            output["allocationAPI"] = ["calibrationPassed": true, "calibrationBytes": 257,
                "calibration": calibration ?? [:],
                "parseAndCompile": allocationDelta(before, after),
                "coverage": "Interposed malloc/calloc/realloc/free API entries and requested bytes; direct zone allocation APIs, compiler-inlined copies and private runtime loops are unmeasured"]
        }
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
        withExtendedLifetime((compiled, retained)) {}
    }

    private static func sample(compiled: CompiledNetlist, policy: BenchmarkPolicy, resources: MeasuredResources,
                               start: ContinuousClock.Instant, mode: String, ordinal: Int,
                               allocationProbe: Bool) async throws -> [String: Any] {
        let allocationBefore = try allocationCapture(enabled: allocationProbe, resume: 1)
        let heapBefore = heap(), resourceBefore = resources.snapshot
        let meter = ResolutionMeter(resources: resources)
        let begin = ContinuousClock.now
        let lowered: LoweredCircuit, options: SPICEAnalysisOptions, command: ParsedAnalysisCommand
        do {
            let scratch = try resources.reserveStorage(kind: .temporaryBytes,
                byteCount: NetlistLowering.resourceEnvelope(limits: policy.resolution).maximumTemporaryBytes)
            var session = try NetlistLowering.beginEvaluation(compiled, profile: policy.profile,
                limits: policy.resolution, seed: policy.seed, control: meter)
            options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
            try session.lower(geometryScale: options.geometryScale)
            guard let circuit = session.circuit, let sourceCommand = compiled.source.analyses.first else {
                throw BenchmarkFailure.invalidResult
            }
            command = try SPICEAnalysisCommands.resolve(sourceCommand, at: 0, from: compiled, session: &session)
            _ = try SPICENodeVoltageResolver().resolve(.initialConditions, compiled: compiled, session: &session, circuit: circuit)
            _ = try SPICENodeVoltageResolver().resolve(.nodeSets, compiled: compiled, session: &session, circuit: circuit)
            lowered = try session.finish()
            withExtendedLifetime(scratch) {}
        }
        let resolvedAt = ContinuousClock.now
        let allocationAfterResolution = try allocationCapture(enabled: allocationProbe, resume: 1)
        let afterResolution = meter.snapshot
        guard case .dc(let sweep) = command else { throw BenchmarkFailure.invalidResult }
        let first = try scalar(sweep.startValue), last = try scalar(sweep.stopValue), step = try scalar(sweep.stepValue)
        guard first == 0, last == 1, step == 0.25 else { throw BenchmarkFailure.invalidResult }
        let values: [Double] = [first, first + step, first + 2 * step, first + 3 * step, last]
        let prepared = try NativeCircuitPreparer().prepare(ir: lowered.circuit, registry: options.deviceRegistry(),
            operatingConditions: options.operatingConditions(), limits: policy.native,
            numericalLimits: policy.numerical, resources: resources)
        let record = prepared.record
        let preparedAt = ContinuousClock.now
        let allocationAfterPreparation = try allocationCapture(enabled: allocationProbe, resume: 1)
        let afterPreparation = meter.snapshot, resourceAfterPreparation = resources.snapshot
        let receipts = record.mosPreparationReceipts
        guard receipts.count == 8, receipts.allSatisfy({ $0.coldSetupCount == 1 }),
              compiled.sameStorage(as: lowered.compiled), afterPreparation == afterResolution else {
            throw BenchmarkFailure.preparationChanged
        }
        let run = try await DCAnalysis(config: options.convergence).runSweep(circuit: prepared,
            source: sweep.source, values: values, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let end = ContinuousClock.now
        let allocationAfter = try allocationCapture(enabled: allocationProbe, resume: 0)
        let heapAfter = heap(), resourceAfterAnalysis = resources.snapshot
        guard meter.snapshot == afterResolution else { throw BenchmarkFailure.downstreamResolutionChanged }
        guard run.phases.count == 5, run.result.results.count == 5,
              run.phases.allSatisfy({ $0.mosPreparationReceipts == receipts && $0.completedPointCount == 1 }),
              resourceAfterAnalysis.work == resourceAfterPreparation.work else { throw BenchmarkFailure.preparationChanged }
        var signature: [[Double]] = []
        for point in run.result.results {
            guard point.variables.allSatisfy(\.isFinite) else { throw BenchmarkFailure.invalidResult }
            signature.append(point.variables)
        }
        guard signature.first != signature.last else { throw BenchmarkFailure.invalidResult }
        let provenance = lowered.evaluationProvenance
        var row: [String: Any] = [
            "mode": mode, "ordinal": ordinal, "totalSeconds": seconds(start, end),
            "resolveSeconds": seconds(begin, resolvedAt), "prepareSeconds": seconds(resolvedAt, preparedAt),
            "analysisSeconds": seconds(preparedAt, end), "heapBeforeResolution": heapBefore, "heapAfter": heapAfter,
            "resourceBefore": try object(resourceBefore), "resourceAfterPreparation": try object(resourceAfterPreparation),
            "resourceAfterAnalysis": try object(resourceAfterAnalysis), "resolutionWork": afterResolution,
            "downstreamResolutionWorkDelta": delta(afterResolution, meter.snapshot),
            "sourceResourceWorkDeltaDuringAnalysis": delta(resourceAfterPreparation.work, resourceAfterAnalysis.work),
            "evaluationSteps": provenance.evaluationSteps, "randomDraws": provenance.randomDraws,
            "rootVisitCount": provenance.rootVisits.count, "randomGeneratorVersion": provenance.randomGeneratorVersion,
            "compiledRetainedBytes": compiled.retainedBytes, "snapshotRetainedBytes": compiled.snapshot.retainedBytes,
            "graphRetainedBytes": lowered.graph.retainedBytes, "graphWorkUnits": lowered.graph.workUnits,
            "evaluationRetainedBytes": provenance.retainedBytes, "evaluationPeakOwnedBufferBytes": provenance.peakOwnedBufferBytes,
            "mosReceipts": receipts.map { ["coldSetupCount": UInt64($0.coldSetupCount),
                "retainedBytes": $0.retainedBytes, "peakTemporaryBytes": $0.peakTemporaryBytes] },
            "resolvedCandidateEvidenceCount": receipts.reduce(0) { $0 + $1.identity.resolved.candidates.count },
            "completedPoints": run.phases.reduce(0) { $0 + $1.completedPointCount },
            "sweepValues": run.result.values, "resultSignature": signature
        ]
        if let statistics = run.statistics { row["numericalStatistics"] = try object(statistics) }
        if let before = allocationBefore, let after = allocationAfter {
            row["allocationAPI"] = allocationDelta(before, after)
            if let resolved = allocationAfterResolution, let prepared = allocationAfterPreparation {
                row["allocationAPIPhases"] = ["resolve": allocationDelta(before, resolved),
                    "prepare": allocationDelta(resolved, prepared), "analysis": allocationDelta(prepared, after)]
            }
        }
        withExtendedLifetime((lowered, record, run)) {}
        return row
    }
    private static func scalar(_ value: ParsedParameterValue) throws -> Double {
        guard case .numeric(let result) = value, result.isFinite else { throw BenchmarkFailure.missingScalar }
        return result
    }
    private static func seconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: end).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func delta(_ before: [String: UInt64], _ after: [String: UInt64]) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for (key, value) in after { result[key] = value - (before[key] ?? 0) }
        return result
    }
    private static func heap() -> [String: UInt64] {
        let value = mos_native_heap_snapshot()
        return ["blocksInUse": value.blocks_in_use, "bytesInUse": value.bytes_in_use,
            "zoneMaximumBytesInUse": value.max_bytes_in_use, "zoneBytesAllocated": value.zone_bytes_allocated,
            "processPeakResidentBytes": value.process_peak_resident_bytes,
            "rusageStatus": UInt64(value.rusage_status == 0 ? 0 : 1)]
    }

    private static func allocationCapture(enabled: Bool, resume: Int32) throws -> MOSAllocationSnapshot? {
        guard enabled else { return nil }
        let snapshot = mos_native_allocation_capture(resume)
        guard snapshot.status == 0 else { throw AllocationFailure.snapshot(snapshot.status) }
        return snapshot
    }

    private static func allocationDelta(_ before: MOSAllocationSnapshot,
                                        _ after: MOSAllocationSnapshot) -> [String: UInt64] {
        ["mallocCalls": after.malloc_calls - before.malloc_calls,
         "callocCalls": after.calloc_calls - before.calloc_calls,
         "reallocCalls": after.realloc_calls - before.realloc_calls,
         "freeCalls": after.free_calls - before.free_calls,
         "requestedBytes": after.requested_bytes - before.requested_bytes,
         "copyCalls": (after.memcpy_calls - before.memcpy_calls)
            + (after.memmove_calls - before.memmove_calls) + (after.bcopy_calls - before.bcopy_calls),
         "copiedBytes": after.copied_bytes - before.copied_bytes]
    }
}
