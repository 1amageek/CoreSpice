import CoreSpiceIO
import CoreSpiceEvent
import Foundation

/// Long-form complete family export; each scalar has explicit case, temperature and seed coordinates.
struct CoreSpiceCLIPreparedFamilyCSV {
    static func write(_ cases: [CoreSpiceCLIPreparedCase], path: String,
                      resources: any SPICESourceResourceAccounting, maximumBytes: UInt64,
                      cancellation: CancellationToken) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        var count: UInt64 = 0
        func row(_ fields: [String]) throws {
            try resources.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
            let text = fields.map { field -> String in
                if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",") + "\n"
            let bytes = UInt64(text.utf8.count)
            guard bytes <= maximumBytes - count else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Prepared family CSV exceeds output ceiling") }
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes)
            try resources.charge(.projectedBytes, units: bytes)
            try handle.write(contentsOf: Data(text.utf8)); count += bytes
            withExtendedLifetime(scratch) { }
        }
        do {
            try row(["case", "temperature_celsius", "nominal_temperature_celsius", "seed", "analysis", "sweep", "coordinate", "variable", "real", "imaginary", "unit", "phase", "low"])
            for run in cases {
                for (point, coordinate) in run.waveform.coordinates.enumerated() {
                    for (variable, descriptor) in run.waveform.variables.enumerated() {
                        let index = point * run.waveform.variables.count + variable
                        try row([String(run.index), String(run.selection.temperatureCelsius), String(run.selection.nominalTemperatureCelsius),
                                 String(run.selection.seed), run.waveform.analysis.rawValue, run.waveform.sweep.name, String(coordinate),
                                 descriptor.name, String(run.waveform.real[index]), run.waveform.imaginary.map { String($0[index]) } ?? "", descriptor.unit.rawValue, "result", ""])
                    }
                }
                if let execution = run.completion.fourierTransientExecution ?? run.completion.osdiExecution,
                   let precision = execution.precision {
                    for (point, coordinate) in execution.coordinates.enumerated() {
                        for (variable, descriptor) in execution.columns.enumerated() {
                            let index = point * execution.columns.count + variable
                            try row([String(run.index), String(run.selection.temperatureCelsius), String(run.selection.nominalTemperatureCelsius),
                                String(run.selection.seed), execution.analysis, execution.sweepName, String(coordinate), descriptor.name,
                                String(execution.real[index]), "", descriptor.unit, "transient-high-low", String(precision.solutionLow[index])])
                        }
                    }
                }
            }
            try handle.close()
        } catch {
            do { try handle.close() }
            catch let closeError { throw CoreSpiceCLIOSDIError.incompleteReceipt("Prepared family CSV failed: \(error); close failed: \(closeError)") }
            throw error
        }
    }
}
