import CoreSpiceEvaluationContracts
import CoreSpiceParsedIR

/// Exact source coordinate for one member of the winning literal temperature family.
public struct NetlistSourceTemperature: Sendable, Hashable {
    public let controlIndex: Int
    public let valueIndex: Int
    public let celsius: Double
    public let temperature: TemperatureKelvin

    init(controlIndex: Int, valueIndex: Int, celsius: Double) throws {
        self.controlIndex = controlIndex; self.valueIndex = valueIndex; self.celsius = celsius
        self.temperature = try TemperatureCelsius(celsius).kelvin
    }

    static func winningAmbientControl(in source: ParsedNetlist, storage: FrontendStorage) throws -> Int? {
        var winner: Int?
        for (index, control) in source.controls.enumerated() {
            try storage.spend()
            switch control {
            case .temp: winner = index
            case .option(let name, _, _) where name.utf8.elementsEqual("temp".utf8, by: {
                ($0 >= 65 && $0 <= 90 ? $0 + 32 : $0) == $1
            }): winner = index
            default: break
            }
        }
        return winner
    }

    static func validate(_ selection: Self?, in source: ParsedNetlist, storage: FrontendStorage) throws {
        let winner = try winningAmbientControl(in: source, storage: storage)
        if let selection {
            guard winner == selection.controlIndex,
                  source.controls.indices.contains(selection.controlIndex),
                  case .temp(.numericVector(let values), _) = source.controls[selection.controlIndex],
                  values.indices.contains(selection.valueIndex), values[selection.valueIndex] == selection.celsius else {
                throw LoweringError.unsupportedFeature(feature: "Temperature selection does not match the winning source family")
            }
        } else if let winner, case .temp(.numericVector, _) = source.controls[winner] {
            throw LoweringError.unsupportedFeature(feature: "Temperature family requires an explicit source selection")
        }
    }
}
