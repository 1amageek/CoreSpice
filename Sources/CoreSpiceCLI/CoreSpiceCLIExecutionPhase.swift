import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceDevices
import CoreSpiceWaveform
import CoreSpiceIO
import CoreSpiceParsedIR
import Synchronization

/// Completed numerical phase and the actual device inputs that produced its observations.
struct CoreSpiceCLIExecutionPhase: Sendable {
    let id: String
    let facts: NativeCircuitExecutionFacts
    let compiled: CompiledNetlist
    var instances: [Instance] { facts.instances }
    var conditions: OperatingConditions { facts.conditions }
    let observations: [String: Double]
    let modelOrigins: [String: ParsedModelOrigin]?
    let diodeModelNames: [String: String]?
}

/// Per-invocation in-memory evidence; callbacks and I/O execute outside its lock.
final class CoreSpiceCLIPhaseCollector: Sendable {
    private struct State: Sendable {
        var phases: [CoreSpiceCLIExecutionPhase] = []
        var metrics: [String: Double] = [:]
        var metricPhases: [String: [String]] = [:]
        var metricSemantics: [String: CoreSpiceCLIMetricSemantics] = [:]
        var sourceCompletionMetricGroups: [String: [String]] = [:]
        var sourceCompletions: [String: CoreSpiceCLISourceCompletion] = [:]
        var sensitivityArtifacts: [String: CoreSpiceCLISensitivityEvidence] = [:]
        var sensitivityMetricGroups: [String: [String]] = [:]
        var sensitivityEncodedBounds: [String: Int] = [:]
        var complete = false
        var instanceRecordCount = 0
        var observationCount = 0
        var retainedByteCharge = 0
        var encodedByteCharge = 0
    }
    private let state = Mutex(State())
    private let maximumRetainedBytes: Int
    private let maximumEncodedBytes: Int

    init(maximumRetainedBytes: Int = 64 * 1024 * 1024, maximumEncodedBytes: Int = 256 * 1024 * 1024) throws {
        guard (1...64 * 1024 * 1024).contains(maximumRetainedBytes),
              (1...256 * 1024 * 1024).contains(maximumEncodedBytes) else {
            throw CoreSpiceCLICaseError.incompleteOutput("invalid evidence history budget")
        }
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    func emptyCopy() throws -> CoreSpiceCLIPhaseCollector {
        try CoreSpiceCLIPhaseCollector(maximumRetainedBytes: maximumRetainedBytes, maximumEncodedBytes: maximumEncodedBytes)
    }

    var phases: [CoreSpiceCLIExecutionPhase] { state.withLock { $0.phases } }
    var metrics: [String: Double] { state.withLock { $0.metrics } }
    var metricPhases: [String: [String]] { state.withLock { $0.metricPhases } }
    var metricSemantics: [String: CoreSpiceCLIMetricSemantics] { state.withLock { $0.metricSemantics } }
    var sourceCompletionMetricGroups: [String: [String]] { state.withLock { $0.sourceCompletionMetricGroups } }
    var sourceCompletions: [String: CoreSpiceCLISourceCompletion] { state.withLock { $0.sourceCompletions } }
    var sensitivityArtifacts: [String: CoreSpiceCLISensitivityEvidence] { state.withLock { $0.sensitivityArtifacts } }
    var sensitivityMetricGroups: [String: [String]] { state.withLock { $0.sensitivityMetricGroups } }
    var sensitivityEncodedBounds: [String: Int] { state.withLock { $0.sensitivityEncodedBounds } }
    var isComplete: Bool { state.withLock { $0.complete } }

    func record(id: String, facts: NativeCircuitExecutionFacts, compiled: CompiledNetlist,
                waveform: WaveformData, poleZeroResult: PoleZeroResult? = nil) throws {
        try Task.checkCancellation()
        guard waveform.pointCount > 0, facts.completedPointCount > 0 else { throw CoreSpiceCLICaseError.incompleteOutput("empty phase waveform") }
        let instances = facts.instances
        var observations: [String: Double] = [:]
        var semantics: [String: CoreSpiceCLIMetricSemantics] = [:]
        if let result = poleZeroResult {
            guard waveform.metadata.analysisType == .poleZero, facts.analysis == "pz" else {
                throw CoreSpiceCLICaseError.incompleteOutput("pole-zero observation does not match the completed phase")
            }
            func add(_ name: String, _ value: Double, gain: Bool = false) throws {
                let observation = try CoreSpiceCLIMetricObservation(name: name,value: value,
                    meaning: .poleZero(name: name,gain: gain))
                observations[observation.name]=observation.value
                semantics[observation.name]=observation.meaning
            }
            try add("dc-gain",result.dcGain,gain: true)
            for (index,pole) in result.poles.enumerated() {
                try add("pole:\(index):real",pole.real); try add("pole:\(index):imag",pole.imag)
            }
            for (index,zero) in result.zeros.enumerated() {
                try add("zero:\(index):real",zero.real); try add("zero:\(index):imag",zero.imag)
            }
        } else {
        for (index, variable) in waveform.variables.enumerated() {
            if waveform.isComplex {
                guard let value = waveform.complexValue(variable: index, point: waveform.pointCount - 1),
                      value.real.isFinite, value.imag.isFinite else {
                    throw CoreSpiceCLICaseError.incompleteOutput("invalid phase sample")
                }
                observations["last:\(variable.name):real"] = value.real
                observations["last:\(variable.name):imag"] = value.imag
                semantics["last:\(variable.name):real"] = .waveform(variable, complexPart: "real")
                semantics["last:\(variable.name):imag"] = .waveform(variable, complexPart: "imag")
            } else {
                guard let value = waveform.realValue(variable: index, point: waveform.pointCount - 1), value.isFinite else {
                    throw CoreSpiceCLICaseError.incompleteOutput("invalid phase sample")
                }
                observations["last:\(variable.name)"] = value
                semantics["last:\(variable.name)"] = .waveform(variable)
            }
        }
        }
        try record(id: id, facts: facts, compiled: compiled, observations: observations, semantics: semantics)
    }

    func record(id: String, facts: NativeCircuitExecutionFacts, compiled: CompiledNetlist,
                observations: [String: Double], semantics: [String: CoreSpiceCLIMetricSemantics],
                contributors: [String: [String]] = [:], modelOrigins: [String: ParsedModelOrigin]? = nil,
                diodeModelNames: [String: String]? = nil) throws {
        try Task.checkCancellation()
        guard facts.completedPointCount > 0, !observations.isEmpty,
              observations.values.allSatisfy(\.isFinite), Set(observations.keys) == Set(semantics.keys),
              Set(contributors.keys).isSubset(of: Set(observations.keys)) else {
            throw CoreSpiceCLICaseError.incompleteOutput("Incomplete completed phase observations")
        }
        let instances = facts.instances
        var charge = id.utf8.count * (1 + observations.count) + observations.keys.reduce(0) { $0 + $1.utf8.count + 128 }
        for instance in instances {
            if case .prepared(let receipt) = instance.diode {
                charge += Int(receipt.retainedBytes) + 4096
            }
            if case .prepared(let receipt) = instance.mos {
                charge += Int(receipt.retainedBytes) + Int(receipt.identity.resolved.retainedBytes)
            }
            charge += instance.name.utf8.count + instance.typeName.utf8.count + 256
            var maps = [instance.parameters]
            if case .selected(let model) = instance.modelConsumption {
                charge += model.name.utf8.count + (model.declarationID?.utf8.count ?? 0)
                maps.append(model.parameters)
            }
            for map in maps {
                for (key, value) in map {
                    charge += key.utf8.count + 128
                    if case .string(let string) = value { charge += string.utf8.count }
                    if case .realVector(let vector) = value { charge += vector.count * 8 }
                }
            }
        }
        charge += semantics.values.reduce(0) { $0 + $1.unitID.utf8.count + $1.extractionID.utf8.count
            + $1.declaredUnit.utf8.count + $1.quantity.utf8.count + $1.unitMeaning.utf8.count + 128 }
        guard charge <= maximumRetainedBytes else {
            throw CoreSpiceCLICaseError.incompleteOutput("phase retained-byte budget exceeded")
        }
        // JSON escaping costs at most six bytes per UTF-8 byte; numeric entries reserve 64 bytes.
        let semanticEncodedCharge = semantics.values.reduce(0) { $0 + ($1.unitID.utf8.count
            + $1.extractionID.utf8.count + $1.declaredUnit.utf8.count + $1.quantity.utf8.count + $1.unitMeaning.utf8.count) * 6 + 256 }
        let encodedCharge = semanticEncodedCharge + id.utf8.count * 6 + 16 + observations.keys.reduce(0) {
            $0 + (id.utf8.count * 3 + $1.utf8.count * 2) * 6 + 160
        }
        let phase = CoreSpiceCLIExecutionPhase(id: id, facts: facts, compiled: compiled, observations: observations, modelOrigins: modelOrigins, diodeModelNames: diodeModelNames)
        try state.withLock { state in
            state.complete = false
            let available = Set(state.phases.map(\.id) + [id])
            guard contributors.values.allSatisfy({ !$0.isEmpty && Set($0).isSubset(of: available) }) else {
                throw CoreSpiceCLICaseError.incompleteOutput("Unknown sensitivity contributor phase")
            }
            guard !state.phases.contains(where: { $0.id == id }) else {
                throw CoreSpiceCLICaseError.incompleteOutput("duplicate phase identity")
            }
            guard charge <= maximumRetainedBytes - state.retainedByteCharge,
                  encodedCharge <= maximumEncodedBytes - state.encodedByteCharge,
                  state.phases.count < 10_000, instances.count <= 100_000 - state.instanceRecordCount,
                  observations.count <= 100_000 - state.observationCount else {
                throw CoreSpiceCLICaseError.incompleteOutput("phase history budget exceeded")
            }
            state.encodedByteCharge += encodedCharge
            state.retainedByteCharge += charge
            state.instanceRecordCount += instances.count
            state.observationCount += observations.count
            state.phases.append(phase)
            for (name, value) in observations {
                let key = "\(id):\(name)"
                state.metrics[key] = value
                state.metricPhases[key] = contributors[name] ?? [id]
                state.metricSemantics[key] = semantics[name]
            }
        }
    }

    func measurements(_ measurements: [SPICEMeasurementResult], prefix: String, phaseIDs: [String]) throws {
        try state.withLock { state in
            state.complete = false
            guard measurements.count <= 100_000 - state.observationCount else {
                throw CoreSpiceCLICaseError.incompleteOutput("measurement history budget exceeded")
            }
            state.observationCount += measurements.count
            for measurement in measurements {
                guard measurement.value.isFinite, !phaseIDs.isEmpty else {
                    throw CoreSpiceCLICaseError.incompleteOutput("invalid measurement or contributors")
                }
                let keyBytes = prefix.utf8.count + 8 + measurement.name.utf8.count
                let retainedCharge = keyBytes + 512 + measurement.unit.utf8.count + measurement.name.utf8.count + phaseIDs.count * 8
                let encodedCharge = keyBytes * 12 + 512 + measurement.unit.utf8.count * 6 + measurement.name.utf8.count * 6
                    + phaseIDs.reduce(0) { $0 + $1.utf8.count * 6 + 8 }
                guard retainedCharge <= maximumRetainedBytes - state.retainedByteCharge,
                      encodedCharge <= maximumEncodedBytes - state.encodedByteCharge else {
                    throw CoreSpiceCLICaseError.incompleteOutput("measurement identity or contributor byte budget exceeded")
                }
                state.retainedByteCharge += retainedCharge
                state.encodedByteCharge += encodedCharge
                let key = "\(prefix)measure:\(measurement.name)"
                guard state.metrics[key] == nil else {
                    throw CoreSpiceCLICaseError.incompleteOutput("duplicate emitted metric identity")
                }
                state.metrics[key] = measurement.value
                state.metricPhases[key] = phaseIDs
                state.metricSemantics[key] = .measurement(name: measurement.name, unit: measurement.unit)
            }
        }
    }

    func sensitivityArtifact(_ evidence: CoreSpiceCLISensitivityEvidence, id: String, prefix: String,
                             resources: any SPICESourceResourceAccounting) throws {
        let upper = try CoreSpiceCLIJSONUpperBound.count(evidence, maximumBytes: UInt64(maximumEncodedBytes), resources: resources)
        try state.withLock { state in
            let metrics = state.metrics.keys.filter { $0.hasPrefix(prefix) }.sorted()
            guard !metrics.isEmpty, state.sensitivityArtifacts[id] == nil,
                  upper <= UInt64(maximumEncodedBytes - state.encodedByteCharge),
                  upper <= UInt64(maximumRetainedBytes - state.retainedByteCharge) else {
                throw CoreSpiceCLICaseError.incompleteOutput("Sensitivity artifact history budget exceeded")
            }
            state.complete = false
            state.retainedByteCharge += Int(upper); state.encodedByteCharge += Int(upper)
            state.sensitivityArtifacts[id] = evidence; state.sensitivityMetricGroups[id] = metrics
            state.sensitivityEncodedBounds[id] = Int(upper)
        }
    }

    func sourceCompletion(_ completion: CoreSpiceCLISourceCompletion, id: String, metricPrefix: String) throws {
        try state.withLock { state in
            let bytes = completion.json.utf8.count
            guard state.sourceCompletions[id] == nil, bytes <= maximumEncodedBytes - state.encodedByteCharge else {
                throw CoreSpiceCLICaseError.incompleteOutput("Source completion history budget exceeded")
            }
            state.encodedByteCharge += bytes; state.sourceCompletions[id] = completion
            state.sourceCompletionMetricGroups[id] = state.metrics.keys.filter { $0.hasPrefix(metricPrefix) }.sorted()
            state.complete = false
        }
    }

    func finish() { state.withLock { $0.complete = true } }
}
