import CoreSpice
import CoreSpiceIR
import CoreSpiceWaveform
import Foundation

/// Exact compiled row identity; optional source names are observed from the execution plan.
public struct CoreSpiceCLIOSDIVariableRecord: Codable, Sendable, Hashable {
    public let row: Int
    public let kind: String
    public let sourceName: String?
    public let unit: String
    public let value: Double

    static func records(_ record: NativeCircuitPreparationRecord, waveform: WaveformData) throws -> [Self]? {
        guard !record.osdiPreparationRecords.isEmpty else { return nil }
        guard waveform.pointCount == 1, waveform.variables.count == record.plan.topology.dimension else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed full operating-point waveform is absent")
        }
        var rows: [Self?] = Array(repeating: nil, count: record.plan.topology.dimension)
        for (variable, row) in record.plan.topology.variableMap {
            guard rows.indices.contains(row), rows[row] == nil else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid compiled global variable mapping")
            }
            guard let value = waveform.realValue(variable: row, point: 0), value.isFinite else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed global row value is absent or nonfinite")
            }
            switch variable {
            case .nodeVoltage(let node):
                rows[row] = Self(row: row, kind: "node", sourceName: record.plan.ir.nodeNames[node],
                    unit: record.osdiVariableKinds[variable] == .thermalPotential ? "K" : "V", value: value)
            case .branchCurrent(let branch):
                rows[row] = Self(row: row, kind: "branch", sourceName: record.plan.ir.branchNames[branch], unit: "A", value: value)
            }
        }
        return try rows.map { value in
            guard let value else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing compiled variable row") }
            return value
        }
    }
    static func validate(models: [CoreSpiceCLIOSDIRecord]?, variables: [Self]?) throws {
        if models == nil && variables == nil { return }
        guard let models, !models.isEmpty, models.allSatisfy({ $0.schemaVersion == 1 && $0.phase == "op" }), let variables, !variables.isEmpty,
              Set(models.map(\.instanceName)).count == models.count,
              variables.map(\.row).sorted() == Array(0..<variables.count) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing or duplicate saved OSDI execution rows")
        }
        let ordered = variables.sorted { $0.row < $1.row }
        for model in models {
            for (index, row) in model.rawNodeGlobalRows.enumerated() {
                if let row {
                    guard ordered.indices.contains(row), ordered[row].unit == model.rawNodeUnits[index] else {
                        throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved OSDI raw/global row or unit mismatch")
                    }
                }
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case row, kind, sourceName, unit, value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        row = try c.decode(Int.self, forKey: .row); kind = try c.decode(String.self, forKey: .kind)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName); unit = try c.decode(String.self, forKey: .unit)
        value = try c.decode(Double.self, forKey: .value)
        guard row >= 0, value.isFinite, (kind == "node" && (unit == "V" || unit == "K")) || (kind == "branch" && unit == "A") else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved compiled variable row")
        }
    }
    private init(row: Int, kind: String, sourceName: String?, unit: String, value: Double) {
        self.row = row; self.kind = kind; self.sourceName = sourceName; self.unit = unit; self.value = value
    }
}
