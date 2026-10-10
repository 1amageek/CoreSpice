import CoreSpice
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceDevices
import CoreSpiceWaveform
import CoreSpiceIO
import Synchronization

/// Completed numerical phase and the actual device inputs that produced its observations.
struct CoreSpiceCLIExecutionPhase: Sendable {
    let id: String
    let facts: NativeCircuitExecutionFacts
    let compiled: CompiledNetlist
    var instances: [Instance] { facts.instances }
    var conditions: OperatingConditions { facts.conditions }
    let observations: [String: Double]
}

/// Per-invocation in-memory evidence; callbacks and I/O execute outside its lock.
final class CoreSpiceCLIPhaseCollector: Sendable {
    private struct State: Sendable {
        var phases: [CoreSpiceCLIExecutionPhase] = []
        var metrics: [String: Double] = [:]
        var metricPhases: [String: [String]] = [:]
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
    var isComplete: Bool { state.withLock { $0.complete } }

    func record(id: String, facts: NativeCircuitExecutionFacts, compiled: CompiledNetlist,
                waveform: WaveformData) throws {
        try Task.checkCancellation()
        guard waveform.pointCount > 0, facts.completedPointCount > 0 else { throw CoreSpiceCLICaseError.incompleteOutput("empty phase waveform") }
        let instances = facts.instances
        var observations: [String: Double] = [:]
        for (index, variable) in waveform.variables.enumerated() {
            if waveform.isComplex {
                guard let value = waveform.complexValue(variable: index, point: waveform.pointCount - 1),
                      value.real.isFinite, value.imag.isFinite else {
                    throw CoreSpiceCLICaseError.incompleteOutput("invalid phase sample")
                }
                observations["last:\(variable.name):real"] = value.real
                observations["last:\(variable.name):imag"] = value.imag
            } else {
                guard let value = waveform.realValue(variable: index, point: waveform.pointCount - 1), value.isFinite else {
                    throw CoreSpiceCLICaseError.incompleteOutput("invalid phase sample")
                }
                observations["last:\(variable.name)"] = value
            }
        }
        var charge = id.utf8.count * (1 + observations.count) + observations.keys.reduce(0) { $0 + $1.utf8.count + 128 }
        for instance in instances {
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
        guard charge <= maximumRetainedBytes else {
            throw CoreSpiceCLICaseError.incompleteOutput("phase retained-byte budget exceeded")
        }
        // JSON escaping costs at most six bytes per UTF-8 byte; numeric entries reserve 64 bytes.
        let encodedCharge = id.utf8.count * 6 + 16 + observations.keys.reduce(0) {
            $0 + (id.utf8.count * 3 + $1.utf8.count * 2) * 6 + 160
        }
        let phase = CoreSpiceCLIExecutionPhase(id: id, facts: facts, compiled: compiled, observations: observations)
        try state.withLock { state in
            state.complete = false
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
                state.metricPhases[key] = [id]
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
                let retainedCharge = keyBytes + 128 + phaseIDs.count * 8
                let encodedCharge = keyBytes * 12 + 128
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
            }
        }
    }

    func finish() { state.withLock { $0.complete = true } }
}
