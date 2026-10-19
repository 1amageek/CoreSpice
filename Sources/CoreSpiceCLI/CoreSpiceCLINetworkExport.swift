import CircuiteFoundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import Foundation

/// Presentation/interchange of the same completed observations; never a second numerical run.
struct CoreSpiceCLINetworkExport {
    private static func check(_ resources: any SPICESourceResourceAccounting, _ cancellation: CancellationToken) throws {
        try resources.checkCancellation()
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    static func writeTouchstone(_ network: CoreSpiceCLINetworkRecord, path: String,
                               resources: any SPICESourceResourceAccounting, maximumBytes: UInt64,
                               cancellation: CancellationToken) throws {
        try check(resources, cancellation)
        try network.validate()
        let rowBytes = try CoreSpiceCLIPrecisionExecution.add(64,
            CoreSpiceCLIPrecisionExecution.multiply(UInt64(network.ports.count * network.ports.count), 64))
        let upper = try CoreSpiceCLIPrecisionExecution.add(4096,
            CoreSpiceCLIPrecisionExecution.add(CoreSpiceCLIPrecisionExecution.multiply(UInt64(network.ports.count), 64),
                CoreSpiceCLIPrecisionExecution.multiply(UInt64(network.points.count), rowBytes)))
        guard upper <= maximumBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Touchstone exceeds output envelope") }
        let scratch = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: CoreSpiceCLIPrecisionExecution.multiply(upper, 4))
        // The ASCII serialization envelope includes every header, reference, data and End token.
        // Each token occupies at least one byte, so the admitted wire-byte bound is also a safe token bound.
        let limits = TouchstoneLimits(maximumInputBytes: maximumBytes, maximumOutputBytes: maximumBytes,
            maximumRetainedBytes: maximumBytes, maximumTokens: upper,
            maximumLineBytes: Int(min(maximumBytes, UInt64(Int.max))), maximumTokenBytes: 256,
            maximumPorts: network.ports.count, maximumFrequencyPoints: network.points.count)
        let points = try network.points.map { point in
            try check(resources, cancellation)
            return try TouchstonePoint(frequencyHz: Double(bitPattern: point.frequencyBits),
                matrix: NetworkParameterMatrix(portCount: network.ports.count, values: point.s.map(\.value)))
        }
        let data = try TouchstoneData(parameterKind: .scattering,
            referenceResistances: network.ports.map { Double(bitPattern: $0.referenceImpedanceBits) }, points: points)
        let encoded = try TouchstoneEncoder().encode(data, configuration: .init(), limits: limits)
        try check(resources, cancellation)
        guard UInt64(encoded.count) <= upper else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Touchstone exceeds admitted serialization") }
        try resources.charge(.projectedBytes, units: UInt64(encoded.count))
        try resources.chargeHashedBytes(UInt64(encoded.count))
        try encoded.write(to: URL(fileURLWithPath: path))
        withExtendedLifetime(scratch) {}
    }

    static func writeCSV(_ cases: [CoreSpiceCLIPreparedCase], path: String,
                         resources: any SPICESourceResourceAccounting, maximumBytes: UInt64,
                         cancellation: CancellationToken) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        var bytes: UInt64 = 0
        func row(_ fields: [String]) throws {
            try check(resources, cancellation)
            let text = fields.map { value in
                value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: ",") + "\n"
            let size = UInt64(text.utf8.count)
            guard size <= maximumBytes - bytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("RF CSV exceeds output ceiling") }
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: CoreSpiceCLIPrecisionExecution.multiply(size, 2))
            try resources.charge(.projectedBytes, units: size)
            try resources.chargeHashedBytes(size)
            try handle.write(contentsOf: Data(text.utf8)); bytes += size
            withExtendedLifetime(scratch) {}
        }
        do {
            try row(["case", "temperature_celsius", "nominal_temperature_celsius", "seed", "frequency_hz", "kind", "response_port", "excitation_port", "real", "imaginary", "availability", "reason", "unit"])
            for run in cases {
                guard let network = run.completion.network else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Non-network member in RF CSV") }
                try network.validate()
                let n = network.ports.count
                for point in network.points {
                    let prefix = [String(run.index), String(run.selection.temperatureCelsius), String(run.selection.nominalTemperatureCelsius),
                        String(run.selection.seed), String(Double(bitPattern: point.frequencyBits))]
                    for (kind, values, unit) in [("S", Optional(point.s), ""), ("Y", Optional(point.y), "S"), ("Z", point.z, "ohm")] {
                        for response in 0..<n { for excitation in 0..<n {
                            let value = values?[response * n + excitation].value
                            try row(prefix + [kind, String(response + 1), String(excitation + 1),
                                value.map { String($0.real) } ?? "", value.map { String($0.imag) } ?? "",
                                value == nil ? "unavailable" : "defined", value == nil ? point.zUnavailableReason ?? "" : "", unit])
                        } }
                    }
                }
            }
            try handle.close()
        } catch {
            do { try handle.close() }
            catch let close { throw CoreSpiceCLIOSDIError.incompleteReceipt("RF CSV failed: \(error); close failed: \(close)") }
            throw error
        }
    }

    static func writeFamily(_ record: CoreSpiceCLIPreparedRunRecord, serializedJSON: String?, directory: String,
                            resources: any SPICESourceResourceAccounting, maximumBytes: UInt64,
                            cancellation: CancellationToken) throws {
        guard let cases = record.cases, cases.allSatisfy({ $0.completion.network != nil }) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing complete RF family")
        }
        struct Member: Codable { let index: Int; let completion: ArtifactReference; let touchstone: ArtifactReference; let completionFile: String; let touchstoneFile: String }
        struct Manifest: Codable { let schemaVersion: Int; let family: ArtifactReference; let members: [Member]; let csv: ArtifactReference }
        let url = URL(fileURLWithPath: directory)
        var total: UInt64 = 0
        func save(_ data: Data, name: String, format: ArtifactFormat) throws -> ArtifactReference {
            try check(resources, cancellation)
            let next = try CoreSpiceCLIPrecisionExecution.add(total, UInt64(data.count))
            guard next <= maximumBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("RF family directory exceeds output ceiling") }
            try resources.charge(.projectedBytes, units: UInt64(data.count))
            try resources.chargeHashedBytes(UInt64(data.count))
            try data.write(to: url.appendingPathComponent(name)); total = next
            let jsonReference = try CoreSpiceCLISourceCompletion.reference(data)
            return try .init(digest: jsonReference.digest, byteCount: jsonReference.byteCount,
                descriptor: .init(role: .output, kind: format == .json ? .report : .waveform, format: format))
        }
        func existing(_ path: String, format: ArtifactFormat) throws -> ArtifactReference {
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
            guard let size else { throw CLIError.state("Missing staged network file size") }
            let next = try CoreSpiceCLIPrecisionExecution.add(total, size.uint64Value)
            guard next <= maximumBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("RF family directory exceeds output ceiling") }
            try resources.chargeHashedBytes(size.uint64Value)
            let reference = try CoreSpiceCLIArtifactReferencer().output(path: path, kind: .waveform, format: format)
            total = next
            return reference
        }
        let family: ArtifactReference
        do {
            let upper = try CoreSpiceCLIJSONUpperBound.count(record, maximumBytes: maximumBytes, resources: resources)
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: CoreSpiceCLIPrecisionExecution.multiply(upper, 4))
            let familyJSON = try serializedJSON ?? CoreSpiceCLIJSON.encode(record)
            family = try save(Data(familyJSON.utf8), name: "family.json", format: .json)
            withExtendedLifetime(scratch) {}
        }
        var members: [Member] = []
        for run in cases {
            try check(resources, cancellation)
            guard let network = run.completion.network else { throw CLIError.state("Missing RF member") }
            let completionName = "case-\(run.index).json"
            let completion: ArtifactReference
            do {
                let upper = try CoreSpiceCLIJSONUpperBound.count(run.completion, maximumBytes: maximumBytes, resources: resources)
                let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: CoreSpiceCLIPrecisionExecution.multiply(upper, 4))
                completion = try save(Data(CoreSpiceCLIJSON.encode(run.completion).utf8), name: completionName, format: .json)
                withExtendedLifetime(scratch) {}
            }
            let touchstoneName = "case-\(run.index).s\(network.ports.count)p"
            let target = url.appendingPathComponent(touchstoneName).path
            try writeTouchstone(network, path: target, resources: resources, maximumBytes: maximumBytes, cancellation: cancellation)
            let touchstone = try existing(target, format: ArtifactFormat(rawValue: "touchstone"))
            members.append(.init(index: run.index, completion: completion, touchstone: touchstone,
                completionFile: completionName, touchstoneFile: touchstoneName))
        }
        let csvPath = url.appendingPathComponent("network.csv").path
        guard FileManager.default.createFile(atPath: csvPath, contents: nil) else { throw CLIError.state("Cannot stage RF CSV") }
        try writeCSV(cases, path: csvPath, resources: resources, maximumBytes: maximumBytes, cancellation: cancellation)
        let csv = try existing(csvPath, format: .csv)
        let manifest = Manifest(schemaVersion: 1, family: family, members: members, csv: csv)
        let upper = try CoreSpiceCLIJSONUpperBound.count(manifest, maximumBytes: maximumBytes, resources: resources)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: CoreSpiceCLIPrecisionExecution.multiply(upper, 4))
        _ = try save(Data(CoreSpiceCLIJSON.encode(manifest).utf8), name: "manifest.json", format: .json)
        withExtendedLifetime(scratch) {}
    }
}
