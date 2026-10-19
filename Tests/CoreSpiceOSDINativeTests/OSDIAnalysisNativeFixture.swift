import Foundation
import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import OSDIContracts
import OSDIRuntime
import Testing

/// Builds the original source lane from explicit model metadata and independent inputs.
struct OSDIAnalysisNativeFixture {
    let manifest: OSDIAnalysisManifest
    let base: OSDINativeFixture
    private let latestSOI101: Bool

    init(libraries: [OSDIDCManifest.Library]? = nil, latestSOI101: Bool = false) throws {
        let key = latestSOI101 ? "CORESPICE_OSDI_SOI101_ANALYSIS_MANIFEST" : "CORESPICE_OSDI_ANALYSIS_MANIFEST"
        let path = try #require(ProcessInfo.processInfo.environment[key])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if latestSOI101 { try OSDIFamilyProfileAdmission.validateLatestSOI101Analysis(data) }
        manifest = try JSONDecoder().decode(OSDIAnalysisManifest.self, from: data)
        base = try OSDINativeFixture(libraries: libraries ?? manifest.libraries)
        self.latestSOI101 = latestSOI101
    }

    func catalog(_ point: OSDIAnalysisManifest.Case) throws -> [String: OSDIResolvedInstance] {
        var result: [String: OSDIResolvedInstance] = [:]
        for device in point.input.circuit.devices {
            let library = try #require(base.libraries.first { $0.id == device.library })
            let parameters = try device.parameters.map { try $0.assignment() }
            let binding = try OSDIModelBinding(modelName: device.id, artifact: try #require(base.references[device.library]),
                descriptorIndex: device.descriptorIndex, expectedDescriptorName: library.descriptorName,
                modelParameters: parameters.filter { $0.scope == .model })
            result[OSDINativeFixture.sourceName(device.id)] = try .init(binding: binding,
                instanceParameters: parameters.filter { $0.scope == .instance }, previousState: device.previousState)
        }
        return result
    }

    func runtime(_ point: OSDIAnalysisManifest.Case, provider: (any OSDILibraryProviding)? = nil) throws -> SPICEOSDIRuntimeInputs {
        let policy = point.input.circuit.policy
        return try .init(provider: provider ?? base.provider,
            loadLimits: .init(maximumDescriptors: 16, maximumMetadataBytes: 4 * 1024 * 1024, maximumStorageBytes: 4 * 1024 * 1024),
            evaluationLimits: .init(maximumWorkspaceBytes: 8 * 1024 * 1024, maximumDiagnosticCount: 256,
                maximumDiagnosticBytes: 65536, maximumStringBytes: 65536), maximumInstanceCount: 16,
            maximumAdapterBytes: 8 * 1024 * 1024,
            tolerances: .init(temperatureAbsoluteKelvin: try #require(policy.unknownAbsoluteTolerances["K"]),
                thermalResidualAbsoluteWatts: try #require(policy.equationAbsoluteTolerances["W"])))
    }

    func input(_ point: OSDIAnalysisManifest.Case, stopTimeOverride: Double? = nil,
               resources: SPICESimulationResources? = nil) async throws -> PreparedSPICESimulation {
        let circuit = point.input.circuit, analysis = point.input.analysis
        var lines = ["S4 original source \(point.id)"]
        for device in circuit.devices {
            let library = try await base.provider.load(reference: try #require(base.references[device.library]),
                limits: .init(maximumDescriptors: 16, maximumMetadataBytes: 4 * 1024 * 1024, maximumStorageBytes: 4 * 1024 * 1024))
            let names: [String]
            do {
                if latestSOI101 {
                    let descriptor = try #require(library.descriptors.first { Int($0.index) == device.descriptorIndex })
                    try #require(descriptor.name == "bsimsoi" && descriptor.terminalCount == 6)
                }
                let parameters = try device.parameters.map { try $0.assignment() }
                let options = try OSDIPreparationOptions(parameters: parameters, simulationParameters: [],
                    temperatureKelvin: device.temperatureKelvin, connectedTerminalCount: device.connectedTerminalCount,
                    limits: runtime(point).evaluationLimits)
                var model = try OSDINativeModelPreparer().prepare(library: library, descriptorIndex: device.descriptorIndex, options: options)
                defer { model.close() }
                if latestSOI101 {
                    try #require(model.topology.nodes.prefix(6).map(\.name) == ["d", "g", "s", "e", "b", "t"])
                }
                names = try model.topology.nodes.prefix(device.connectedTerminalCount).map { try #require(device.terminals[$0.name]) }
            } catch { try library.close(); throw error }
            try library.close()
            lines += [".model \(device.id) osdi", "\(OSDINativeFixture.sourceName(device.id)) \(names.joined(separator: " ")) \(device.id)"]
        }
        for part in circuit.resistors { lines.append("\(part.id) \(part.positive) \(part.negative) \(part.value)") }
        for part in circuit.voltageSources + circuit.currentSources {
            var tail = "\(part.value)"
            if part.id == analysis.stimulus?.sourceID {
                if let points = analysis.stimulus?.points, points.count > 1 {
                    tail = "PWL(" + points.map { "\($0.timeSeconds) \($0.value)" }.joined(separator: " ") + ")"
                } else if let value = analysis.stimulus?.points?.first?.value { tail = "\(value)" }
                if let real = analysis.stimulus?.real, let imag = analysis.stimulus?.imag {
                    tail += " AC \(hypot(real, imag)) acphase=\(atan2(imag, real) * 180 / .pi)"
                }
            }
            lines.append("\(part.id) \(part.positive) \(part.negative) \(tail)")
        }
        let policy = circuit.policy
        let ambient = try #require(circuit.devices.first).temperatureKelvin
        lines.append(".options temp=\(ambient - 273.15) tnom=27 gmin=0 reltol=\(policy.relativeTolerance) abstol=\(try #require(policy.equationAbsoluteTolerances["A"])) vntol=\(try #require(policy.equationAbsoluteTolerances["V"])) itl1=\(policy.maximumIterations)")
        if analysis.initialization == "uic" {
            for (name, value) in (analysis.uicInitialUnknowns ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard name.hasPrefix("net:") else { throw OSDIDCManifest.Failure.invalidManifest }
                lines.append(".ic V(\(name.dropFirst(4)))=\(value)")
            }
        } else {
            for (name, value) in circuit.initialUnknowns.sorted(by: { $0.key < $1.key }) where name.hasPrefix("net:") {
                lines.append(".nodeset V(\(name.dropFirst(4)))=\(value)")
            }
        }
        switch point.kind {
        case "ac":
            let frequencies = try #require(analysis.frequenciesHz)
            let endpoints = try OSDIFamilyProfileAdmission.decadeSweepEndpoints(frequencies)
            lines.append(".ac dec 1 \(endpoints.first) \(endpoints.last)")
        case "noise":
            let frequencies = try #require(analysis.frequenciesHz), output = try #require(analysis.output)
            let endpoints = try OSDIFamilyProfileAdmission.decadeSweepEndpoints(frequencies)
            guard output.positiveUnknownID.hasPrefix("net:") else { throw OSDIDCManifest.Failure.invalidManifest }
            let positive = String(output.positiveUnknownID.dropFirst(4))
            let node: String
            if let negative = output.negativeUnknownID {
                guard negative.hasPrefix("net:") else { throw OSDIDCManifest.Failure.invalidManifest }
                node = "V(\(positive),\(negative.dropFirst(4)))"
            } else { node = "V(\(positive))" }
            lines.append(".noise \(node) \(try #require(analysis.inputSourceID)) dec 1 \(endpoints.first) \(endpoints.last)")
        case "transient":
            let steps = try #require(analysis.steps)
            let first = try #require(steps.first), last = try #require(steps.last)
            lines.append(".tran \(first.timeStepSeconds) \(stopTimeOverride ?? last.timeSeconds) 0 \(first.timeStepSeconds)" + (analysis.initialization == "uic" ? " uic" : ""))
        default: throw OSDIDCManifest.Failure.invalidManifest
        }
        lines.append(".end")
        return try await base.source(lines.joined(separator: "\n") + "\n", catalog: catalog(point), resources: resources)
    }
}
