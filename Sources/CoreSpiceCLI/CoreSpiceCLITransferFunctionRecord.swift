import CircuiteFoundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceWaveform
import Foundation

/// Exact completed TF values, including ports without a finite numeric impedance.
struct CoreSpiceCLITransferFunctionRecord: Codable, Sendable {
    struct Impedance: Codable, Sendable, Equatable {
        let classification: String
        let valueBits: UInt64?
        init(_ value: PortImpedance) {
            switch value {
            case .finite(let value): classification = "finite"; valueBits = value.bitPattern
            case .openCircuit: classification = "open_circuit"; valueBits = nil
            }
        }
        func validate() throws {
            guard (classification == "finite" && valueBits.map({ Double(bitPattern: $0).isFinite }) == true) ||
                  (classification == "open_circuit" && valueBits == nil) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved TF port impedance")
            }
        }
    }
    let schemaVersion: Int
    let gainBits: UInt64
    let input: Impedance
    let output: Impedance
    let sourceArtifacts: [ArtifactReference]
    private let reservation: SPICESourceStorageReservation?
    private enum CodingKeys: String, CodingKey { case schemaVersion, gainBits, input, output, sourceArtifacts }

    init(_ completed: SPICENativeSimulationOutput) throws {
        guard let result = completed.tfResult, completed.waveform.metadata.analysisType == .transferFunction else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Actual completed TF result is missing")
        }
        let bytes = try CoreSpiceCLIPrecisionExecution.add(512,
            CoreSpiceCLIPrecisionExecution.multiply(UInt64(completed.prepared.input.sources.count), UInt64(MemoryLayout<ArtifactReference>.stride)))
        reservation = try completed.prepared.input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        schemaVersion = 1; gainBits = result.gain.bitPattern
        input = .init(result.inputPortImpedance); output = .init(result.outputPortImpedance)
        sourceArtifacts = completed.prepared.input.sources.map { $0.binding.reference }
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        gainBits = try c.decode(UInt64.self, forKey: .gainBits)
        input = try c.decode(Impedance.self, forKey: .input)
        output = try c.decode(Impedance.self, forKey: .output)
        sourceArtifacts = try c.decode([ArtifactReference].self, forKey: .sourceArtifacts)
        reservation = nil
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1, Double(bitPattern: gainBits).isFinite,
              !sourceArtifacts.isEmpty else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid completed TF record")
        }
        try input.validate(); try output.validate()
    }

    func validateWaveform(_ waveform: CoreSpiceCLIPreparedWaveform) throws {
        try validate(); try waveform.validate()
        var names = ["gain"], units: [SIUnit] = [.dimensionless], bits = [gainBits]
        for (name, port) in [("Zin", input), ("Zout", output)] {
            if let value = port.valueBits { names.append(name); units.append(.ohm); bits.append(value) }
        }
        guard waveform.analysis == .transferFunction, waveform.coordinates.map(\.bitPattern) == [Double(0).bitPattern],
              waveform.imaginary == nil, waveform.sweep.name == "point", waveform.sweep.index == 0,
              waveform.sweep.unit == .dimensionless, waveform.sweep.type == .parameter,
              waveform.variables.map(\.name) == names, waveform.variables.map(\.unit) == units,
              waveform.variables.allSatisfy({ $0.type == .voltage }), waveform.real.map(\.bitPattern) == bits,
              waveform.options == ["input_port_impedance": input.classification, "output_port_impedance": output.classification] else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved TF waveform differs from completed port values")
        }
    }
}
