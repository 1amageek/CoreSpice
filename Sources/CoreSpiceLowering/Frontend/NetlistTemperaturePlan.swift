import CoreSpiceMOSResolution
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Evaluation-free, bounded selection of the two winning global condition roots.
struct NetlistTemperaturePlan {
    let ambient: MOSConditionInput
    let nominal: MOSConditionInput
    let provenance: NetlistTemperatureProvenance

    init(compiled: CompiledNetlist, policy: NetlistTemperaturePolicy, storage: FrontendStorage) throws {
        var ambient = MOSConditionInput.temperature(policy.defaults.ambient)
        var nominal = MOSConditionInput.temperature(policy.defaults.nominal)
        var ambientOrigin = NetlistTemperatureProvenance.Origin.callerDefault
        var nominalOrigin = NetlistTemperatureProvenance.Origin.callerDefault
        for (index, control) in compiled.source.controls.enumerated() {
            try storage.spend()
            let condition: Bool
            let location: SourceLocation?
            switch control {
            case .temp(_, let source): condition = true; location = source
            case .option(let name, _, let source) where name.lowercased() == "temp": condition = true; location = source
            case .option(let name, _, let source) where name.lowercased() == "tnom": condition = false; location = source
            default: continue
            }
            let slot = try compiled.scalarSlot(at: .control(index: index, field: "value"))
            let source = location.map { MOSSourceOccurrence(captureID: nil, occurrenceID: nil,
                path: $0.file, line: $0.line, column: $0.column, statementByteOffset: nil,
                statementOrdinal: UInt64(index)) }
            if condition {
                ambient = .program(slot.program, invocation: 0, lexicalScope: .init(0), source: source)
                ambientOrigin = .sourceControl(index)
            } else {
                nominal = .program(slot.program, invocation: 0, lexicalScope: .init(0), source: source)
                nominalOrigin = .sourceControl(index)
            }
        }
        if let value = policy.ambientOverride { ambient = .temperature(value); ambientOrigin = .callerOverride }
        if let value = policy.nominalOverride { nominal = .temperature(value); nominalOrigin = .callerOverride }
        self.ambient = ambient; self.nominal = nominal
        provenance = .init(ambient: ambientOrigin, nominal: nominalOrigin)
    }
}
