import Foundation
import OSDIContracts

/// Inspection-only, bit-exact projection of one effective simulation parameter.
public struct CoreSpiceCLIOSDISimulationParameterRecord: Codable, Sendable, Hashable {
    public let name: String
    public let type: String
    public let realValueBits: UInt64?
    public let stringValue: String?

    private enum CodingKeys: String, CodingKey { case name, type, realValueBits, stringValue }

    public init(_ parameter: OSDISimulationParameter) throws {
        name = parameter.name
        switch parameter.value {
        case .real(let value): type = "real"; realValueBits = value.bitPattern; stringValue = nil
        case .string(let value): type = "string"; realValueBits = nil; stringValue = value
        case .integer: throw CoreSpiceCLIOSDIError.incompleteReceipt("Integer simulation parameter is unsupported")
        }
        _ = try simulationParameter()
    }

    func simulationParameter() throws -> OSDISimulationParameter {
        switch type {
        case "real":
            guard let realValueBits, stringValue == nil else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid real simulation parameter payload")
            }
            return try .init(name: name, value: .real(Double(bitPattern: realValueBits)))
        case "string":
            guard let stringValue, realValueBits == nil else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid string simulation parameter payload")
            }
            return try .init(name: name, value: .string(stringValue))
        default: throw CoreSpiceCLIOSDIError.incompleteReceipt("Unknown simulation parameter type")
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        realValueBits = try c.decodeIfPresent(UInt64.self, forKey: .realValueBits)
        stringValue = try c.decodeIfPresent(String.self, forKey: .stringValue)
        guard (type == "real" && !c.contains(.stringValue)) ||
              (type == "string" && !c.contains(.realValueBits)) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Conflicting simulation parameter payload")
        }
        _ = try simulationParameter()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.type == rhs.type &&
        lhs.realValueBits == rhs.realValueBits && {
            switch (lhs.stringValue, rhs.stringValue) {
            case (.none, .none): return true
            case (.some(let l), .some(let r)): return l.utf8.elementsEqual(r.utf8)
            default: return false
            }
        }()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name.utf8.count)
        for byte in name.utf8 { hasher.combine(byte) }
        hasher.combine(type); hasher.combine(realValueBits)
        hasher.combine(stringValue != nil)
        if let stringValue {
            hasher.combine(stringValue.utf8.count)
            for byte in stringValue.utf8 { hasher.combine(byte) }
        }
    }
}
