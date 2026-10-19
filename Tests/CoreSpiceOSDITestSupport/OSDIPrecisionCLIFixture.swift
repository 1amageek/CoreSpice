import Foundation
import CircuiteFoundation
import CoreSpiceOSDI

/// Exact source/catalog inputs only; the caller owns execution and temporary cleanup.
package struct OSDIPrecisionCLIFixture {
    package let root: URL
    package let deck: URL
    package let catalog: URL
    package let csv: URL
    package let pairedCSV: URL
    package let catalogJSON: [String: Any]
    package let executionBudget: [String: UInt64]
    package var json: [String: Any] { catalogJSON }
    package var workerPath: URL { root.appendingPathComponent("precision-worker") }

    package static func make(modelID: String, manifest: OSDIPrecisionManifest, root: URL,
                             pointID: String? = nil, pilot: Bool = true) async throws -> Self {
        guard let model = manifest.models.first(where: { $0.id == modelID }) else { throw OSDIDCManifest.Failure.invalidManifest }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let point: OSDIAnalysisManifest.Case?
        let topology: OSDIDCManifest.PreparedDevice?
        if modelID == "compound" || modelID == "context" {
            point = nil; topology = nil
        } else {
            let analysis: OSDIAnalysisManifest = try environmentManifest("CORESPICE_OSDI_ANALYSIS_MANIFEST")
            let defaultID: String
            switch modelID {
            case "bsim", "cmg": defaultID = modelID + "-n-loaded-s4-transient"
            case "img": defaultID = "img-n-thermal-s4-transient"
            case "soi": defaultID = "soi-n-series-thermal-s4-transient"
            default: throw OSDIDCManifest.Failure.invalidManifest
            }
            guard let selected = analysis.cases.first(where: { $0.id == (pointID ?? defaultID) }),
                  selected.kind == "transient", selected.input.circuit.devices.count == 1,
                  let device = selected.input.circuit.devices.first, device.library == modelID,
                  device.descriptorIndex == model.descriptorIndex else {
                throw OSDIDCManifest.Failure.invalidManifest
            }
            point = selected
            let dc: OSDIDCManifest = try environmentManifest("CORESPICE_OSDI_PRECISION_DC_MANIFEST")
            topology = try metadataWitness(for: model, connectedTerminalCount: device.connectedTerminalCount, manifest: dc)
        }
        let nodeCount = topology?.rawNodes.count ?? 1
        // Use the adapter owner's actual representation sizes, including the cold
        // program/setup ceilings. These fixtures have exactly one model/worker.
        let extra = try OSDIAdapterCapacity.precision(nodeCount: nodeCount, options: manifest.options.value())
        let workerBytes = try sum(manifest.options.arenaBytes, manifest.options.maximumMappingBytes)
        let adapter = try sum(8 * 1024 * 1024, extra)
        // Preserve the verified API fixture's 64/128 MiB Native/live envelopes
        // and add the explicitly owned worker+precision storage. Temporary/hash
        // ceilings stay explicit; evidence is a caller-selected serialization
        // envelope and must fail admission if insufficient, without auto-growth.
        let budget: [String: UInt64] = [
            "maximumNativeAllocationBytes": try sum(64 * 1024 * 1024, workerBytes, extra),
            "maximumLiveOwnedBytes": try sum(128 * 1024 * 1024, workerBytes, extra),
            "maximumTemporaryBytes": 128 * 1024 * 1024,
            "maximumHashedBytes": 64 * 1024 * 1024,
            "maximumEvidenceBytes": 128 * 1024 * 1024]
        let imageName = "model.osdi", workerName = "precision-worker"
        try FileManager.default.copyItem(atPath: model.path, toPath: root.appendingPathComponent(imageName).path)
        try FileManager.default.copyItem(atPath: manifest.worker.path, toPath: root.appendingPathComponent(workerName).path)
        let reference = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: model.sha256),
            byteCount: model.byteCount, descriptor: .init(role: .input, kind: .model, format: .unknown))
        let workerReference = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: manifest.worker.sha256),
            byteCount: manifest.worker.byteCount, descriptor: .init(role: .input, kind: .other, format: .raw))
        let device = point?.input.circuit.devices.first
        let instanceName = device.map { "n_" + $0.id.lowercased() } ?? "n1"
        let modelName = device?.id ?? "model"
        let assignments = try (device?.parameters ?? []).map { parameter -> [String: Any] in
            _ = try parameter.assignment()
            let value: Any
            switch parameter.value.kind {
            case "real": guard let given = parameter.value.real else { throw OSDIDCManifest.Failure.invalidManifest }; value = given
            case "integer": guard let given = parameter.value.integer else { throw OSDIDCManifest.Failure.invalidManifest }; value = given
            case "string": guard let given = parameter.value.string else { throw OSDIDCManifest.Failure.invalidManifest }; value = given
            default: throw OSDIDCManifest.Failure.invalidManifest
            }
            return ["name": parameter.name, "scope": parameter.scope, "type": parameter.value.kind, "value": value]
        }
        let options = manifest.options
        let json: [String: Any] = ["schemaVersion": 2, "libraryRootPath": root.path, "stagingParentDirectory": root.path,
            "artifacts": [["reference": try object(reference), "relativePath": [imageName], "accessBudget": accessBudget(model.byteCount)]],
            "instances": [["instanceName": instanceName, "modelName": modelName, "artifact": try object(reference),
                "descriptorIndex": model.descriptorIndex, "expectedDescriptorName": model.descriptorName,
                "modelParameters": assignments.filter { $0["scope"] as? String == "model" },
                "instanceParameters": assignments.filter { $0["scope"] as? String == "instance" }, "previousState": device?.previousState ?? []]],
            "loadLimits": ["maximumDescriptors": 16, "maximumMetadataBytes": 4 * 1024 * 1024, "maximumStorageBytes": 4 * 1024 * 1024],
            "evaluationLimits": ["maximumWorkspaceBytes": 8 * 1024 * 1024, "maximumDiagnosticCount": 256,
                "maximumDiagnosticBytes": 65536, "maximumStringBytes": 65536],
            "maximumInstanceCount": 16, "maximumAdapterBytes": adapter,
            "tolerances": ["temperatureAbsoluteKelvin": point?.input.circuit.policy.unknownAbsoluteTolerances["K"] ?? 1e-6,
                "thermalResidualAbsoluteWatts": point?.input.circuit.policy.equationAbsoluteTolerances["W"] ?? 1e-12],
            "executionBudget": budget,
            "transientPrecision": ["workerRootPath": root.path,
                "worker": ["reference": try object(workerReference), "relativePath": [workerName], "accessBudget": accessBudget(manifest.worker.byteCount)],
                "semanticProfileSHA256": manifest.semanticProfileSHA256, "numericProfileSHA256": manifest.numericProfileSHA256,
                "precisionBits": manifest.precisionBits,
                "options": ["maximumProgramBytes": options.maximumProgramBytes, "maximumMappingBytes": options.maximumMappingBytes,
                    "arenaBytes": options.arenaBytes, "maximumWorkUnits": options.maximumWorkUnits,
                    "minimumPrecisionBits": UInt64(options.minimumPrecisionBits), "maximumPrecisionBits": UInt64(options.maximumPrecisionBits),
                    "startupTimeoutNanoseconds": options.startupTimeoutNanoseconds, "evaluationTimeoutNanoseconds": options.evaluationTimeoutNanoseconds,
                    "cleanupTimeoutNanoseconds": options.cleanupTimeoutNanoseconds, "pollNanoseconds": options.pollNanoseconds]]]
        let source: String
        if let point, let topology { source = try familySource(point, topology: topology, pilot: pilot) }
        else { source = compoundSource(modelID: modelID) }
        let deck = root.appendingPathComponent("input.cir"), catalog = root.appendingPathComponent("catalog.json")
        try source.write(to: deck, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: catalog)
        return .init(root: root, deck: deck, catalog: catalog, csv: root.appendingPathComponent("waveform.csv"),
            pairedCSV: root.appendingPathComponent("paired.csv"), catalogJSON: json, executionBudget: budget)
    }

    package static func metadataWitness(for model: OSDIPrecisionManifest.Model, connectedTerminalCount: Int,
                                        manifest: OSDIDCManifest) throws -> OSDIDCManifest.PreparedDevice {
        let libraries = manifest.libraries.filter { $0.id == model.id }
        guard libraries.count == 1, let library = libraries.first,
              library.sha256 == model.sha256, library.descriptorIndex == model.descriptorIndex,
              library.descriptorName == model.descriptorName, connectedTerminalCount > 0,
              let sample = manifest.cases.first(where: { candidate in
                  candidate.input.devices.contains { $0.library == model.id && $0.descriptorIndex == model.descriptorIndex && $0.connectedTerminalCount == connectedTerminalCount }
              }), let original = sample.input.devices.first(where: {
                  $0.library == model.id && $0.descriptorIndex == model.descriptorIndex && $0.connectedTerminalCount == connectedTerminalCount
              }), let raw = sample.reference.devices.first(where: { $0.id == original.id }),
              raw.rawNodes.count >= connectedTerminalCount,
              raw.rawNodes.enumerated().allSatisfy({ $0.offset == $0.element.index && !$0.element.name.isEmpty }) else {
            throw OSDIDCManifest.Failure.invalidManifest
        }
        return raw
    }

    private static func familySource(_ point: OSDIAnalysisManifest.Case, topology: OSDIDCManifest.PreparedDevice, pilot: Bool) throws -> String {
        let circuit = point.input.circuit, analysis = point.input.analysis
        guard let device = circuit.devices.first, let steps = analysis.steps, let first = steps.first, let last = steps.last,
              let voltageTolerance = circuit.policy.equationAbsoluteTolerances["V"], let currentTolerance = circuit.policy.equationAbsoluteTolerances["A"] else {
            throw OSDIDCManifest.Failure.invalidManifest
        }
        let terminals = try topology.rawNodes.prefix(device.connectedTerminalCount).map { node in
            guard let value = device.terminals[node.name] else { throw OSDIDCManifest.Failure.invalidManifest }; return value
        }
        var lines = ["Native precision CLI \(point.id)", ".model \(device.id) osdi", "N_\(device.id) \(terminals.joined(separator: " ")) \(device.id)"]
        for part in circuit.resistors { lines.append("\(part.id) \(part.positive) \(part.negative) \(part.value)") }
        for part in circuit.voltageSources + circuit.currentSources {
            var value = String(part.value)
            if part.id == analysis.stimulus?.sourceID, let points = analysis.stimulus?.points, let start = points.first {
                guard start.timeSeconds == 0 && start.value == part.value else { throw OSDIDCManifest.Failure.invalidManifest }
                if points.count > 1 { value = "PWL(" + points.map { "\($0.timeSeconds) \($0.value)" }.joined(separator: " ") + ")" }
                else { value = String(start.value) }
            }
            lines.append("\(part.id) \(part.positive) \(part.negative) \(value)")
        }
        lines.append(".options temp=\(device.temperatureKelvin - 273.15) tnom=27 gmin=0 reltol=\(circuit.policy.relativeTolerance) abstol=\(currentTolerance) vntol=\(voltageTolerance) itl1=\(circuit.policy.maximumIterations) tranmaxaccepted=1000 tranmaxattempts=10000 tranmaxiterations=100000 tranmaxscalars=100000 tranmaxdimension=256 tranmaxwork=1000000000 tranmaxbreakpoints=100")
        let initials = analysis.initialization == "uic" ? analysis.uicInitialUnknowns ?? [:] : circuit.initialUnknowns
        for (name, value) in initials.sorted(by: { $0.key < $1.key }) where name.hasPrefix("net:") {
            lines.append("\(analysis.initialization == "uic" ? ".ic" : ".nodeset") V(\(name.dropFirst(4)))=\(value)")
        }
        lines += [".tran \(first.timeStepSeconds) \(pilot ? first.timeSeconds : last.timeSeconds) 0 \(first.timeStepSeconds)" + (analysis.initialization == "uic" ? " uic" : ""), ".end", ""]
        return lines.joined(separator: "\n")
    }

    private static func compoundSource(modelID: String) -> String {
        let h = modelID == "context" ? 1e-9 : 0x1p-54
        let current = modelID == "context" ? 1.0 : 2.0 + 0x1p-30
        return ["Native precision CLI \(modelID)", ".model model osdi", "N1 p model", "I1 p 0 \(-current)", ".ic V(p)=1",
            ".options gmin=0 reltol=1e-10 abstol=1e-12 vntol=1e-9 itl1=80",
            ".tran \(h) \(4 * h) 0 \(h) uic", ".end", ""].joined(separator: "\n")
    }

    private static func environmentManifest<Value: Decodable>(_ name: String) throws -> Value {
        guard let path = ProcessInfo.processInfo.environment[name] else { throw OSDIDCManifest.Failure.invalidManifest }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    private static func object<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func accessBudget(_ count: UInt64) -> [String: UInt64] {
        ["maximumPageByteCount": min(65536, count), "maximumTotalByteCount": count,
         "maximumPageCount": 65536, "maximumWorkUnitCount": 65536, "maximumDurationNanoseconds": 10_000_000_000]
    }
    private static func sum(_ values: UInt64...) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values { let (next, overflow) = total.addingReportingOverflow(value); guard !overflow else { throw OSDIDCManifest.Failure.invalidManifest }; total = next }
        return total
    }
}
