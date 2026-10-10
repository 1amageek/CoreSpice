import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CoreSpiceIO
import CoreSpiceIR
import ToolQualification
import ToolQualificationCLICore
import Foundation
import Darwin

/// Immutable publication of original executor evidence, separate from qualification issuance.
struct CoreSpiceCLICasePublisher: Sendable {
    static let maximumPublishedBytes = 256 * 1024 * 1024

    struct ExecutableCapture: Sendable {
        let bytes: Data
        let reference: ArtifactReference
    }

    static func captureExecutable(path: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]) throws -> ExecutableCapture {
        let bytes = try LocalSPICESourceReader().read(at: path,
            maximumByteCount: UInt64(maximumPublishedBytes), maximumPageByteCount: 64 * 1024)
        let digest = try SHA256ContentDigester().digest(data: bytes, using: .sha256)
        return ExecutableCapture(bytes: bytes, reference: try ArtifactReference(digest: digest,
            byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .other, format: .unknown)))
    }


    private let publicationBoundary: @Sendable () -> Void

    init(publicationBoundary: @escaping @Sendable () -> Void = {}) {
        self.publicationBoundary = publicationBoundary
    }

    private func checkCancellation() throws {
        publicationBoundary()
        try Task.checkCancellation()
    }

    func publish(directory: String, caseID: String, loadedDeck: LoadedSPICEDeck,
                 phases: CoreSpiceCLIPhaseCollector, referencer: CoreSpiceCLIArtifactReferencer,
                 executableCapture: ExecutableCapture? = nil) throws -> [ArtifactReference] {
        do {
            return try publishComplete(directory: directory, caseID: caseID, loadedDeck: loadedDeck,
                phases: phases, referencer: referencer,
                executableCapture: try executableCapture ?? Self.captureExecutable())
        } catch let error as CoreSpiceCLICaseError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw CoreSpiceCLICaseError.publication(error.localizedDescription) }
    }

    private func publishComplete(directory: String, caseID: String, loadedDeck: LoadedSPICEDeck,
        phases: CoreSpiceCLIPhaseCollector, referencer: CoreSpiceCLIArtifactReferencer,
        executableCapture: ExecutableCapture) throws -> [ArtifactReference] {
        try checkCancellation()
        guard phases.isComplete, !phases.phases.isEmpty, !phases.metrics.isEmpty else {
            throw CoreSpiceCLICaseError.incompleteOutput("execution or observations did not complete")
        }
        let executionID = UUID().uuidString.lowercased()
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let staging = root.deletingLastPathComponent().appendingPathComponent(".corespice-case-\(executionID)")
        let rootID = try ArtifactRootID(rawValue: "corespice-case-\(executionID)")
        guard mkdir(staging.path, 0o700) == 0 else {
            throw CoreSpiceCLICaseError.publication("cannot exclusively create staging directory")
        }
        var committed = false
        defer {
            if !committed {
                do { try FileManager.default.removeItem(at: staging) }
                catch { fputs("case cleanup failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        var byteCount = 0
        var availabilities: [ArtifactAvailability] = []
        var outputs: [ArtifactReference] = []
        var inputs: [ArtifactReference] = []
        var captures: [String: ArtifactReference] = [:]
        var publishedIDs: Set<ArtifactID> = []
        func admitEncoded(_ upperBound: Int) throws {
            try checkCancellation()
            guard upperBound <= Self.maximumPublishedBytes - byteCount else {
                throw CoreSpiceCLICaseError.publication("encoded output budget exceeded before serialization")
            }
        }
        func numericCharge(_ values: [String: Double]) -> Int {
            values.keys.reduce(2) { $0 + $1.utf8.count * 6 + 64 }
        }
        func tokenCharge(_ values: [String]) -> Int {
            values.reduce(0) { $0 + $1.utf8.count * 6 + 8 }
        }
        func write(_ bytes: Data, name: String) throws {
            try checkCancellation()
            guard bytes.count <= Self.maximumPublishedBytes - byteCount else {
                throw CoreSpiceCLICaseError.publication("output byte budget exceeded")
            }
            try bytes.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
            byteCount += bytes.count
        }
        func retain(_ reference: ArtifactReference, name: String) throws {
            guard publishedIDs.insert(reference.id).inserted else { return }
            availabilities.append(.local(artifactID: reference.id, rootID: rootID,
                relativePath: try ArtifactRelativePath(segments: [name])))
        }
        for (index, capture) in loadedDeck.captures.enumerated() {
            let reference = referencer.input(capture: capture, kind: .netlist, format: .spice)
            captures[capture.captureID] = reference
            if !inputs.contains(reference) {
                let name = "input-\(index).spice"
                try write(capture.bytes, name: name)
                guard try referencer.input(path: staging.appendingPathComponent(name).path,
                    kind: .netlist, format: .spice) == reference else {
                    throw CoreSpiceCLICaseError.publication("captured input identity changed")
                }
                inputs.append(reference)
                try retain(reference, name: name)
            }
        }
        // The original executable is a distinct evidence input, never a path-only claim.
        let executable = executableCapture.reference
        try write(executableCapture.bytes, name: "executable")
        guard executable == (try referencer.input(path: staging.appendingPathComponent("executable").path,
            kind: .other, format: .unknown)) else {
            throw CoreSpiceCLICaseError.publication("executable changed during capture")
        }
        try retain(executable, name: "executable")
        let origins = loadedDeck.modelOrigins
        var receipts: [ArtifactReference] = []
        for phase in phases.phases {
            try checkCancellation()
            typealias ModelGroup = (name: String, version: String?, instances: [String: [String: Double]], resolved: [String: Double])
            var groups: [String: [ModelGroup]] = [:]
            for instance in phase.instances {
                try checkCancellation()
                let declaration: String
                let modelName: String
                let version: String?
                var effective: [String: Double]
                let resolved: [String: Double]
                if case .prepared(let receipt) = instance.mos {
                    let selected = receipt.identity.resolved
                    guard let origin = try phase.compiled.modelOrigin(for: selected),
                          origins[origin.declarationID] != nil else {
                        throw CoreSpiceCLICaseError.missingModelOrigin(instance.name)
                    }
                    declaration = origin.declarationID
                    modelName = selected.symbolNames[Int(selected.selectedName.rawValue)]
                    version = selected.release.exactVersion
                    resolved = Dictionary(uniqueKeysWithValues: selected.modelCoefficients.map {
                        (selected.symbolNames[Int($0.symbol.rawValue)], $0.value)
                    })
                    effective = Dictionary(uniqueKeysWithValues: selected.instanceParameters.map {
                        (selected.symbolNames[Int($0.symbol.rawValue)], $0.value)
                    })
                    effective["l"] = selected.normalizedGeometry.length
                    effective["w"] = selected.normalizedGeometry.width
                    effective["ad"] = selected.normalizedGeometry.drainArea
                    effective["as"] = selected.normalizedGeometry.sourceArea
                    effective["pd"] = selected.normalizedGeometry.drainPerimeter
                    effective["ps"] = selected.normalizedGeometry.sourcePerimeter
                } else {
                    switch instance.modelConsumption {
                    case .unrecorded: throw CoreSpiceCLICaseError.unrecordedModelConsumption(instance.name)
                    case .modelFree: continue
                    case .selected(let model):
                        guard let identity = model.declarationID else {
                            throw CoreSpiceCLICaseError.missingModelOrigin(instance.name)
                        }
                        declaration = identity; modelName = model.name
                        if case .string(let value) = model.parameters["version"] { version = value } else { version = nil }
                        effective = try numeric(instance.parameters); resolved = try numeric(model.parameters)
                    }
                }
                guard let origin = origins[declaration], captures[origin.captureID] != nil else {
                    throw CoreSpiceCLICaseError.missingModelOrigin(instance.name)
                }
                effective["operating.temperatureKelvin"] = phase.conditions.temperatureKelvin
                effective["operating.nominalTemperatureKelvin"] = phase.conditions.nominalTemperatureKelvin
                var variants = groups[declaration] ?? []
                let index = variants.firstIndex { $0.resolved == resolved } ?? variants.count
                if index == variants.count { variants.append((modelName, version, [:], resolved)) }
                guard variants[index].instances.updateValue(effective, forKey: instance.name) == nil else {
                    throw CoreSpiceCLICaseError.incompleteOutput("duplicate consumed instance")
                }
                groups[declaration] = variants
            }
            for declaration in groups.keys.sorted() {
                guard let variants = groups[declaration], let origin = origins[declaration],
                      let source = captures[origin.captureID] else {
                    throw CoreSpiceCLICaseError.missingModelOrigin(declaration)
                }
                for (modelName, version, instances, resolved) in variants {
                    // All references use fixed SHA-256 identities and CLI-owned descriptors (<1024 encoded bytes).
                    let receiptCharge = 4096 + inputs.count * 1024
                        + tokenCharge([caseID, executionID, phase.id, declaration, modelName, version ?? ""])
                        + numericCharge(resolved) + instances.reduce(2) {
                            $0 + $1.key.utf8.count * 6 + 8 + numericCharge($1.value)
                        }
                    try admitEncoded(receiptCharge)
                    let receipt = ToolQualificationModelExecutionReceipt(caseID: caseID, executionID: executionID,
                        producer: referencer.producer, phaseID: phase.id, modelID: declaration,
                        sourceArtifact: source, selectedModelIdentifier: modelName,
                        consumedInstances: instances, inputArtifacts: inputs, modelVersion: version,
                        resolvedParameters: resolved)
                    let name = "model-receipt-\(receipts.count).json"
                    try write(receipt.canonicalData(), name: name)
                    let reference = try referencer.output(path: staging.appendingPathComponent(name).path,
                        kind: .report, format: .json)
                    receipts.append(reference)
                    outputs.append(reference)
                    try retain(reference, name: name)
                }
            }
        }
        let executionCharge = 4096 + (inputs.count + receipts.count) * 1024
            + tokenCharge([caseID, executionID]) + tokenCharge(phases.phases.map(\.id))
            + numericCharge(phases.metrics) + phases.metricPhases.reduce(2) {
                $0 + $1.key.utf8.count * 6 + 8 + tokenCharge($1.value)
            }
        try admitEncoded(executionCharge)
        let execution = ToolQualificationCaseExecution(caseID: caseID, executionID: executionID,
            producer: referencer.producer, executableArtifact: executable, inputArtifacts: inputs,
            phaseIDs: phases.phases.map(\.id), metricPhaseIDs: phases.metricPhases,
            modelReceiptArtifacts: receipts, observedMetrics: phases.metrics)
        try write(execution.canonicalData(), name: "execution.json")
        let reference = try referencer.output(path: staging.appendingPathComponent("execution.json").path,
            kind: .report, format: .json)
        outputs.append(reference)
        try retain(reference, name: "execution.json")
        try admitEncoded(4096 + availabilities.count * 1024)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let budget = try ArtifactAccessBudget(maximumPageByteCount: 1024 * 1024,
            maximumTotalByteCount: UInt64(Self.maximumPublishedBytes), maximumPageCount: 100_000,
            maximumWorkUnitCount: 1_000_000_000, maximumDurationNanoseconds: 60_000_000_000)
        try write(encoder.encode(ToolQualificationCLIArtifactAvailabilityInventory(rootID: rootID,
            budget: budget, availabilities: availabilities)), name: "availability.json")
        // Exclusive atomic rename leaves no final case directory for incomplete output.
        try checkCancellation()
        guard renamex_np(staging.path, root.path, UInt32(RENAME_EXCL)) == 0 else {
            throw CoreSpiceCLICaseError.publication("destination exists or cannot be published")
        }
        committed = true
        return outputs
    }

    private func numeric(_ parameters: [String: ParameterValue]) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for (name, value) in parameters {
            switch value {
            case .real(let number):
                guard number.isFinite else { throw CoreSpiceCLICaseError.incompleteOutput("nonfinite instance/model input") }
                result[name] = number
            case .integer(let number): result[name] = Double(number)
            case .string: continue
            default: throw CoreSpiceCLICaseError.incompleteOutput("unrepresentable numeric model input: \(name)")
            }
        }
        return result
    }
}
