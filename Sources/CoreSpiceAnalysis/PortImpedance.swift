/// The classified small-signal impedance of an electrical port.
public enum PortImpedance: Sendable, Equatable {
    case finite(Double)
    case openCircuit

    /// Classifies a represented impedance; positive infinity denotes an explicit open port.
    public init(ohms: Double) throws {
        if ohms == .infinity { self = .openCircuit }
        else {
            guard ohms.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(field: "portImpedance", index: 0, value: ohms)
            }
            self = .finite(ohms)
        }
    }

    /// Classifies the response to a unit voltage, preserving every nonzero current.
    public init(reciprocalOf current: Double) throws {
        guard current.isFinite else {
            throw AnalysisResultValidationError.nonFiniteValue(field: "portCurrent", index: 0, value: current)
        }
        if current == 0 { self = .openCircuit; return }
        let impedance = 1 / current
        guard impedance.isFinite else {
            throw AnalysisResultValidationError.nonFiniteValue(field: "portImpedance", index: 0, value: impedance)
        }
        self = .finite(impedance)
    }

    /// Numeric compatibility projection; an open circuit has positive infinite impedance.
    public var ohms: Double {
        switch self {
        case .finite(let value): return value
        case .openCircuit: return .infinity
        }
    }

    func validate(field: String) throws {
        if case .finite(let value) = self, !value.isFinite {
            throw AnalysisResultValidationError.nonFiniteValue(field: field, index: 0, value: value)
        }
    }
}
