import CircuiteFoundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceIO
import Foundation

/// Original selected physical observations and their source-coordinate finite difference.
struct CoreSpiceCLISensitivityEvidence: Codable, Sendable {
    struct Sample: Codable, Sendable, Equatable {
        let realBits: UInt64
        let imaginaryBits: UInt64?
        let lowBits: UInt64?
        init(scalar: Double) { realBits = scalar.bitPattern; lowBits = 0; imaginaryBits = nil }
        init(_ value: CompensatedValue) { realBits = value.high.bitPattern; lowBits = value.low.bitPattern; imaginaryBits = nil }
        init(real: Double, imaginary: Double) { realBits = real.bitPattern; imaginaryBits = imaginary.bitPattern; lowBits = nil }
        var real: Double { Double(bitPattern: realBits) }
        func validate(complex: Bool) throws {
            guard real.isFinite, complex == (imaginaryBits != nil), complex == (lowBits == nil),
                  imaginaryBits.map({ Double(bitPattern: $0).isFinite }) ?? true,
                  lowBits.map({ Double(bitPattern: $0).isFinite }) ?? true else {
                throw CoreSpiceCLICaseError.incompleteOutput("Invalid original sensitivity observation")
            }
        }
    }
    struct Child: Codable, Sendable {
        let instance: String
        let parameter: String
        let nominalBits: UInt64
        let replacementBits: UInt64
        let increment: Sample
        let outputNode: Int
        let referenceNode: Int?
        let observations: [Sample]
        let absolute: [Sample]
        let normalized: [Sample?]
        let source: CoreSpiceCLIPreparedReexecution
    }
    let sourceArtifacts: [ArtifactReference]
    let schemaVersion: Int
    let analysis: String
    let sourceInputIdentity: String
    let configurationIdentity: String
    let outputVariable: String
    let outputNode: Int
    let referenceNode: Int?
    let frequencies: [Double]
    let baseline: [Sample]
    let children: [Child]
    private var accounting: (any SPICESourceResourceAccounting)? = nil
    private var reservation: SPICESourceStorageReservation? = nil
    private enum CodingKeys: String, CodingKey {
        case sourceArtifacts, schemaVersion, analysis, sourceInputIdentity, configurationIdentity, outputVariable,
             outputNode, referenceNode, frequencies, baseline, children
    }

    init(_ output: SPICENativeSimulationOutput) throws {
        schemaVersion = 1; sourceInputIdentity = output.sourceInputIdentity.hexadecimalValue
        configurationIdentity = output.configurationIdentity.hexadecimalValue
        let records = output.phases.first(where: { $0.sourceReexecutionLedger != nil })?.sourceReexecutions ?? []
        let sampleCount = output.acSensitivityResult?.frequencies.count ?? 1
        var capacity = try CoreSpiceCLIPrecisionExecution.multiply(UInt64(records.count + 1),
            CoreSpiceCLIPrecisionExecution.add(4096, CoreSpiceCLIPrecisionExecution.multiply(UInt64(sampleCount), 256)))
        capacity = try CoreSpiceCLIPrecisionExecution.add(capacity,
            CoreSpiceCLIPrecisionExecution.multiply(UInt64(output.prepared.input.sources.count), UInt64(MemoryLayout<ArtifactReference>.stride)))
        for record in records {
            for scalar in record.sourceOverrides {
                capacity = try CoreSpiceCLIPrecisionExecution.add(capacity, UInt64(scalar.instanceName.utf8.count + scalar.parameterName.utf8.count + 256))
            }
            for completed in record.completedPhase.osdiPreparationRecords {
                let receipt = completed.receipt
                var metadata = UInt64(4096 + receipt.resolved.previousState.count * 8)
                for node in receipt.topology.nodes {
                    metadata = try CoreSpiceCLIPrecisionExecution.add(metadata, UInt64(node.name.utf8.count + node.units.utf8.count + node.residualUnits.utf8.count + 256))
                }
                for parameter in receipt.resolved.binding.modelParameters + receipt.resolved.instanceParameters {
                    metadata = try CoreSpiceCLIPrecisionExecution.add(metadata, UInt64(parameter.name.utf8.count + 256))
                    if case .string(let value) = parameter.value { metadata = try CoreSpiceCLIPrecisionExecution.add(metadata, UInt64(value.utf8.count)) }
                }
                for fact in receipt.resolvedParameters {
                    for name in fact.parameter.names { metadata = try CoreSpiceCLIPrecisionExecution.add(metadata, UInt64(name.utf8.count)) }
                    metadata = try CoreSpiceCLIPrecisionExecution.add(metadata, 256)
                    if case .string(let value) = fact.value { metadata = try CoreSpiceCLIPrecisionExecution.add(metadata, UInt64(value.utf8.count)) }
                }
                capacity = try CoreSpiceCLIPrecisionExecution.add(capacity, CoreSpiceCLIPrecisionExecution.multiply(metadata, 2))
            }
            for receipt in record.preparation.mosPreparationReceipts {
                let model = receipt.identity.resolved
                capacity = try CoreSpiceCLIPrecisionExecution.add(capacity, UInt64(model.retainedBytes) + UInt64(receipt.retainedBytes))
            }
            for receipt in record.preparation.diodePreparationReceipts {
                capacity = try CoreSpiceCLIPrecisionExecution.add(capacity, UInt64(receipt.retainedBytes) + 32768)
            }
        }
        let admitted = try output.prepared.input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: capacity)
        sourceArtifacts = output.prepared.input.sources.map { $0.binding.reference }
        var children: [Child] = []
        if let result = output.sensitivityResult, let selected = result.baselineOutput, let node = result.outputNode {
            analysis = "sens-dc"; outputVariable = result.outputVariable; outputNode = node.id; referenceNode = nil
            frequencies = []; baseline = [.init(selected)]
            guard records.count == result.sensitivities.count else { throw CoreSpiceCLICaseError.incompleteOutput("Sensitivity child completion count differs") }
            for (index, entry) in result.sensitivities.enumerated() {
                guard let value = entry.perturbedValue, let increment = entry.effectiveIncrement,
                      let selected = entry.perturbedOutput, let node = entry.outputNode else {
                    throw CoreSpiceCLICaseError.incompleteOutput("Original DC sensitivity child observation is missing")
                }
                children.append(.init(instance: entry.deviceName, parameter: entry.parameterName,
                    nominalBits: entry.nominalValue.bitPattern, replacementBits: value.bitPattern,
                    increment: .init(increment), outputNode: node.id, referenceNode: nil,
                    observations: [.init(selected)], absolute: [.init(scalar: entry.sensitivity)],
                    normalized: [entry.normalizedSensitivity.map { .init(scalar: $0) }],
                    source: try .init(records[index], phase: "sens", completedPoints: 1)))
            }
        } else if let result = output.acSensitivityResult, let node = result.outputPositiveNode {
            analysis = "sens-ac"; outputVariable = result.outputVariable; outputNode = node.id
            referenceNode = result.outputReferenceNode?.id; frequencies = result.frequencies
            baseline = result.baselineValues.map { .init(real: $0.real, imaginary: $0.imag) }
            guard records.count == result.sensitivities.count else { throw CoreSpiceCLICaseError.incompleteOutput("AC sensitivity child completion count differs") }
            for (index, entry) in result.sensitivities.enumerated() {
                guard let value = entry.perturbedValue, let increment = entry.effectiveIncrement,
                      let selected = entry.perturbedValues, let node = entry.outputPositiveNode else {
                    throw CoreSpiceCLICaseError.incompleteOutput("Original AC sensitivity child observation is missing")
                }
                children.append(.init(instance: entry.deviceName, parameter: entry.parameterName,
                    nominalBits: entry.nominalValue.bitPattern, replacementBits: value.bitPattern,
                    increment: .init(increment), outputNode: node.id, referenceNode: entry.outputReferenceNode?.id,
                    observations: selected.map { .init(real: $0.real, imaginary: $0.imag) },
                    absolute: entry.sensitivities.map { .init(real: $0.real, imaginary: $0.imag) },
                    normalized: entry.normalizedSensitivities.map { $0.map { .init(real: $0.real, imaginary: $0.imag) } },
                    source: try .init(records[index], phase: "sens-ac", completedPoints: result.frequencies.count)))
            }
        } else { throw CoreSpiceCLICaseError.incompleteOutput("Original sensitivity baseline observation is missing") }
        self.children = children
        accounting = output.prepared.input.resources; reservation = admitted
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceArtifacts = try c.decode([ArtifactReference].self, forKey: .sourceArtifacts)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); analysis = try c.decode(String.self, forKey: .analysis)
        sourceInputIdentity = try c.decode(String.self, forKey: .sourceInputIdentity)
        configurationIdentity = try c.decode(String.self, forKey: .configurationIdentity)
        outputVariable = try c.decode(String.self, forKey: .outputVariable); outputNode = try c.decode(Int.self, forKey: .outputNode)
        referenceNode = try c.decodeIfPresent(Int.self, forKey: .referenceNode)
        frequencies = try c.decode([Double].self, forKey: .frequencies)
        baseline = try c.decode([Sample].self, forKey: .baseline); children = try c.decode([Child].self, forKey: .children)
        reservation = nil; try validate()
    }

    func withJSONBytes<Result>(_ body: (Data) throws -> Result) throws -> Result {
        guard let accounting else { throw CoreSpiceCLICaseError.incompleteOutput("Decoded sensitivity evidence cannot authorize publication") }
        let upper = try CoreSpiceCLIJSONUpperBound.count(self, maximumBytes: 64 * 1024 * 1024, resources: accounting)
        let scratch = try accounting.reserveStorage(kind: .temporaryBytes,
            byteCount: CoreSpiceCLIPrecisionExecution.multiply(upper, 4))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        _ = try JSONDecoder().decode(Self.self, from: bytes)
        let result = try body(bytes)
        withExtendedLifetime(scratch) { }
        return result
    }

    func validateWaveform(_ waveform: CoreSpiceCLIPreparedWaveform) throws {
        guard waveform.analysis.rawValue == "sens" else { throw CoreSpiceCLICaseError.incompleteOutput("Sensitivity waveform domain differs") }
        if analysis == "sens-dc" {
            let normalized = children.allSatisfy { $0.normalized[0] != nil }
            let names = normalized ? ["sensitivity", "normalized_sensitivity"] : ["sensitivity"]
            guard waveform.variables.map(\.name) == names, waveform.imaginary == nil,
                  waveform.coordinates.count == children.count else { throw CoreSpiceCLICaseError.incompleteOutput("DC sensitivity waveform geometry differs") }
            for (point, child) in children.enumerated() {
                guard waveform.coordinates[point].bitPattern == Double(point).bitPattern,
                      waveform.real[point * names.count].bitPattern == child.absolute[0].realBits,
                      !normalized || waveform.real[point * names.count + 1].bitPattern == child.normalized[0]?.realBits else {
                    throw CoreSpiceCLICaseError.incompleteOutput("DC sensitivity waveform differs from original derivation")
                }
            }
        } else {
            var names: [String] = []
            for child in children {
                let base = child.instance + "." + child.parameter
                names.append("d" + outputVariable + "/d" + base)
                if child.normalized.allSatisfy({ $0 != nil }) { names.append("normalized_" + base) }
            }
            guard waveform.variables.map(\.name) == names,
                  waveform.coordinates.map(\.bitPattern) == frequencies.map(\.bitPattern),
                  let imaginary = waveform.imaginary else { throw CoreSpiceCLICaseError.incompleteOutput("AC sensitivity waveform geometry differs") }
            for point in frequencies.indices {
                var column = 0
                for child in children {
                    let values = child.normalized.allSatisfy({ $0 != nil }) ? [child.absolute[point], child.normalized[point]!] : [child.absolute[point]]
                    for sample in values {
                        let index = point * names.count + column
                        guard waveform.real[index].bitPattern == sample.realBits, imaginary[index].bitPattern == sample.imaginaryBits else {
                            throw CoreSpiceCLICaseError.incompleteOutput("AC sensitivity waveform differs from original derivation")
                        }
                        column += 1
                    }
                }
            }
        }
    }

    func validate() throws {
        let complex = analysis == "sens-ac", count = complex ? frequencies.count : 1
        guard !sourceArtifacts.isEmpty, schemaVersion == 1, ["sens-dc", "sens-ac"].contains(analysis), !outputVariable.isEmpty,
              outputNode >= 0, referenceNode.map({ $0 >= 0 }) ?? true,
              (complex ? (!frequencies.isEmpty && frequencies.allSatisfy({ $0.isFinite && $0 > 0 })) : frequencies.isEmpty),
              baseline.count == count, !children.isEmpty else { throw CoreSpiceCLICaseError.incompleteOutput("Incomplete original sensitivity derivation") }
        guard [sourceInputIdentity, configurationIdentity].allSatisfy({ value in
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }), zip(frequencies, frequencies.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw CoreSpiceCLICaseError.incompleteOutput("Invalid sensitivity identity or frequency order")
        }
        for sample in baseline { try sample.validate(complex: complex) }
        var identities = Set<String>()
        for child in children {
            let nominal = Double(bitPattern: child.nominalBits), replacement = Double(bitPattern: child.replacementBits)
            let increment = try CompensatedValue(high: child.increment.real, low: Double(bitPattern: child.increment.lowBits ?? 0))
            guard nominal.isFinite, replacement.isFinite, increment != .zero,
                  try CompensatedValue(high: replacement).subtracting(CompensatedValue(high: nominal)) == increment,
                  child.observations.count == count, child.absolute.count == count, child.normalized.count == count,
                  identities.insert(child.instance.lowercased() + "." + child.parameter).inserted,
                  child.source.sourceInputIdentity == sourceInputIdentity,
                  child.source.deviceName == child.instance, child.source.parameterName == child.parameter,
                  child.source.nominalValue.bitPattern == child.nominalBits, child.source.perturbedValue.bitPattern == child.replacementBits,
                  child.source.effectiveIncrement == child.increment, child.source.outputNode == child.outputNode,
                  child.source.referenceNode == child.referenceNode, child.source.observations == child.observations,
                  child.source.frequencies == frequencies else {
                throw CoreSpiceCLICaseError.incompleteOutput("Sensitivity child identity, increment or observation count differs")
            }
            try child.increment.validate(complex: false); try child.source.validate()
            for index in 0..<count {
                try child.observations[index].validate(complex: complex); try child.absolute[index].validate(complex: complex)
                if let normalized = child.normalized[index] { try normalized.validate(complex: complex) }
                let base = baseline[index], changed = child.observations[index]
                let real = try CompensatedValue(high: changed.real, low: Double(bitPattern: changed.lowBits ?? 0))
                    .subtracting(CompensatedValue(high: base.real, low: Double(bitPattern: base.lowBits ?? 0)))
                    .divided(by: increment)
                guard child.absolute[index].realBits == (real.high + real.low).bitPattern else {
                    throw CoreSpiceCLICaseError.incompleteOutput("Sensitivity derivative differs from its original solved observations")
                }
                if complex {
                    let imaginary = try CompensatedValue(high: Double(bitPattern: changed.imaginaryBits!))
                        .subtracting(CompensatedValue(high: Double(bitPattern: base.imaginaryBits!))).divided(by: increment)
                    guard child.absolute[index].imaginaryBits == (imaginary.high + imaginary.low).bitPattern else {
                        throw CoreSpiceCLICaseError.incompleteOutput("AC sensitivity derivative differs from its original solved observations")
                    }
                }
                if baseline[index].real == 0 && (baseline[index].imaginaryBits.map { Double(bitPattern: $0) == 0 } ?? true) &&
                    (baseline[index].lowBits.map { Double(bitPattern: $0) == 0 } ?? true) && child.normalized[index] != nil {
                    throw CoreSpiceCLICaseError.incompleteOutput("Normalized sensitivity is defined for a zero baseline")
                }
            }
        }
    }
}
