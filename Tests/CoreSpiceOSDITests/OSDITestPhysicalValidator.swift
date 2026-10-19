import CoreSpiceOSDITestSupport
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceOSDI

struct OSDITestPhysicalValidator: DCPhysicalResidualValidating {
    let input: OSDIDCManifest.Input
    let devices: [any BoundDevice]
    let nodeIndices: [String: Int]
    let branchIndices: [String: Int]
    let rows: [DCEquationRowPolicy]

    func validate(state: SolutionState) throws {
        var residual = [Double](repeating: 0, count: rows.count)
        for device in devices {
            if let physical = device as? any OSDIPhysicalResidualContributing {
                try physical.accumulatePhysicalResidual(state: state) { residual[$0] += $1 }
            }
        }
        func value(_ name: String) throws -> Double {
            if name == "0" { return 0 }
            guard let index = nodeIndices[name] else { throw OSDIDCManifest.Failure.missingMapping(name) }
            return try state.checkedValue(at: index)
        }
        func add(_ name: String, _ value: Double) {
            if let index = nodeIndices[name] { residual[index] += value }
        }
        for resistor in input.resistors {
            let current = try (value(resistor.positive) - value(resistor.negative)) / resistor.value
            add(resistor.positive, current); add(resistor.negative, -current)
        }
        for source in input.currentSources { add(source.positive, source.value); add(source.negative, -source.value) }
        for source in input.voltageSources {
            guard let index = branchIndices[source.id] else { throw OSDIDCManifest.Failure.missingMapping(source.id) }
            let current = try state.checkedValue(at: index)
            add(source.positive, current); add(source.negative, -current)
            residual[index] += try value(source.positive) - value(source.negative) - source.value
        }
        for index in residual.indices {
            guard residual[index].isFinite, abs(residual[index]) <= rows[index].equationAbsoluteTolerance else {
                throw OSDIDCManifest.Failure.physicalResidual(row: index, value: residual[index])
            }
        }
    }
}
