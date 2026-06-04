import Foundation
import Testing
import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO

@Suite("SPICEIO end-to-end tests")
struct SPICEIOEndToEndTests {

    @Test("Public API parses, lowers, analyzes, and exports an operating-point deck")
    func publicAPIParsesLowersAnalyzesAndExportsOperatingPointDeck() async throws {
        let source = """
        public api e2e divider
        V1 in 0 dc 5
        R1 in out 1k
        R2 out 0 1k
        .op
        .end
        """

        let circuit = try compileAndBindElectricalCircuit(try await SPICEIO.parseAndLower(source))
        let outNode = try node(fromInstance: "r1", terminal: 1, in: circuit.ir)

        let result = try await DCAnalysis().run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )
        #expect(approximately(result.voltage(at: outNode), 2.5, tolerance: 1e-9))

        let waveform = WaveformData.from(
            dcResult: result,
            topology: circuit.plan.topology.circuitTopology,
            title: "Public API E2E"
        )
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove temporary directory: \(error)")
            }
        }

        let csvURL = directory.appendingPathComponent("result.csv")
        let rawURL = directory.appendingPathComponent("result.raw")
        let csvExport = try await SPICEIO.exportToCSV(waveform, path: csvURL.path)
        let rawExport = try await SPICEIO.exportToRAW(waveform, path: rawURL.path)

        #expect(csvExport.success)
        #expect(csvExport.pointsExported == 1)
        #expect(rawExport.success)
        #expect(rawExport.pointsExported == 1)
        #expect(try fileSize(at: csvURL) > 0)
        #expect(try fileSize(at: rawURL) > 0)
        let rawData = try Data(contentsOf: rawURL)
        #expect(rawData.containsASCII("Title: Public API E2E"))
        #expect(rawData.containsASCII("No. Points: 1"))
        #expect(rawData.containsASCII("V(\(outNode.id))"))

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("V(\(outNode.id))"))
        #expect(csv.split(separator: "\n").count == 2)
        #expect(approximately(try exportedValue(named: "V(\(outNode.id))", inCSV: csv), 2.5, tolerance: 1e-9))
    }

    @Test("SPICE serialization round trip preserves executable subcircuit semantics")
    func spiceSerializationRoundTripPreservesExecutableSubcircuitSemantics() async throws {
        let source = """
        serializer e2e asymmetric divider
        .param scale=2
        .subckt divider high low out params: top=1000 bottom=2000
        Rtop high out r={top * scale}
        Rbot out low r={bottom}
        .ends divider
        V1 in 0 dc 9
        X1 in 0 out divider top=2000 bottom=1000
        .op
        .end
        """

        let originalNetlist = try await SPICEIO.parse(source).get()
        let serialized = SPICESerializer().serialize(originalNetlist, options: .default)
        let roundTrippedNetlist = try await SPICEIO.parse(serialized).get()

        let originalVoltage = try await runSubcircuitDividerOutputVoltage(originalNetlist)
        let roundTrippedVoltage = try await runSubcircuitDividerOutputVoltage(roundTrippedNetlist)

        #expect(approximately(originalVoltage, 1.8, tolerance: 1e-9))
        #expect(approximately(roundTrippedVoltage, 1.8, tolerance: 1e-9))
        #expect(approximately(originalVoltage, roundTrippedVoltage, tolerance: 1e-12))
    }
}

private struct ExecutableElectricalCircuit {
    let ir: CircuitIR
    let plan: ExecutionPlan
    let devices: [any BoundDevice]
}

private func compileAndBindElectricalCircuit(_ ir: CircuitIR) throws -> ExecutableElectricalCircuit {
    let plan = try StandardCompiler().compile(ir: ir)
    let registry = DeviceRegistry.standard()
    let structure = plan.matrixStructure
    var context = BindingContext(
        variableMap: plan.topology.variableMap,
        matrixDimension: plan.topology.dimension,
        stampIndexResolver: { row, col in
            structure.index(row: row, col: col)
        }
    )

    var devices: [any BoundDevice] = []
    devices.reserveCapacity(ir.instances.count)
    for instance in ir.instances {
        let descriptor = try #require(
            registry.descriptor(for: instance.typeName),
            "Missing descriptor for \(instance.typeName)"
        )
        devices.append(try descriptor.bind(instance: instance, context: &context))
    }

    return ExecutableElectricalCircuit(ir: ir, plan: plan, devices: devices)
}

private func runSubcircuitDividerOutputVoltage(_ netlist: ParsedNetlist) async throws -> Double {
    let ir = try SPICEIO.lower(netlist, configuration: .default)
    let circuit = try compileAndBindElectricalCircuit(ir)
    let outputNode = try node(fromInstance: "x1.rtop", terminal: 1, in: circuit.ir)

    let result = try await DCAnalysis().run(
        plan: circuit.plan,
        devices: circuit.devices,
        solver: SparseLUSolver(),
        observer: nil,
        cancellation: CancellationToken()
    )
    return result.voltage(at: outputNode)
}

private func node(fromInstance instanceName: String, terminal: Int, in ir: CircuitIR) throws -> Node {
    let instance = try #require(ir.instances.first { $0.name == instanceName })
    guard terminal >= 0, terminal < instance.nodes.count else {
        Issue.record("Terminal \(terminal) is out of range for \(instanceName)")
        throw SPICEIOEndToEndTestError.invalidTerminal
    }
    return instance.nodes[terminal]
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "corespice-spiceio-e2e-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileSize(at url: URL) throws -> Int {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return values.fileSize ?? 0
}

private func exportedValue(named variableName: String, inCSV csv: String) throws -> Double {
    let lines = csv.split(separator: "\n").map(String.init)
    guard lines.count == 2 else {
        Issue.record("Expected CSV header and one data row, got \(lines.count) rows")
        throw SPICEIOEndToEndTestError.invalidCSV
    }

    let headers = lines[0].split(separator: ",").map(String.init)
    let values = lines[1].split(separator: ",").map(String.init)
    let column = try #require(headers.firstIndex { header in
        header.split(separator: " ").first.map(String.init) == variableName
    })
    guard column < values.count, let value = Double(values[column]) else {
        Issue.record("CSV column \(column) is missing or non-numeric")
        throw SPICEIOEndToEndTestError.invalidCSV
    }
    return value
}

private func approximately(_ value: Double, _ expected: Double, tolerance: Double) -> Bool {
    abs(value - expected) <= tolerance * max(1.0, abs(expected))
}

private extension Data {
    func containsASCII(_ text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}

private enum SPICEIOEndToEndTestError: Error {
    case invalidCSV
    case invalidTerminal
}
