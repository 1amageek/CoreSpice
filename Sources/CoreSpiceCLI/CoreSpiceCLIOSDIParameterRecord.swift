import Foundation
import OSDIContracts

/// Host JSON boundary preserving explicit parameter scope and scalar kind.
public struct CoreSpiceCLIOSDIParameterRecord: Codable, Sendable, Hashable {
    public let name: String
    public let scope: String
    public let type: String
    public let descriptorIndex: Int?
    public let isGiven: Bool?
    private let realValue: Double?
    private let integerValue: Int32?
    private let stringValue: String?

    private enum CodingKeys: String, CodingKey { case name, scope, type, value, descriptorIndex, isGiven }
    public init(_ assignment: OSDIParameterAssignment, descriptorIndex: Int? = nil, isGiven: Bool? = nil) {
        name = assignment.name
        switch assignment.scope { case .model: scope = "model"; case .instance: scope = "instance" }
        self.descriptorIndex = descriptorIndex; self.isGiven = isGiven
        switch assignment.value {
        case .real(let value): type = "real"; realValue = value; integerValue = nil; stringValue = nil
        case .integer(let value): type = "integer"; realValue = nil; integerValue = value; stringValue = nil
        case .string(let value): type = "string"; realValue = nil; integerValue = nil; stringValue = value
        }
    }
    func assignment() throws -> OSDIParameterAssignment {
        let selectedScope: OSDIParameterScope
        switch scope { case "model": selectedScope = .model; case "instance": selectedScope = .instance
        default: throw CoreSpiceCLIOSDIError.invalidCatalog("Unknown parameter scope") }
        let selectedValue: OSDIParameterValue
        switch type {
        case "real": guard let realValue else { throw CoreSpiceCLIOSDIError.invalidCatalog("Missing real value") }; selectedValue = .real(realValue)
        case "integer": guard let integerValue else { throw CoreSpiceCLIOSDIError.invalidCatalog("Missing integer value") }; selectedValue = .integer(integerValue)
        case "string": guard let stringValue else { throw CoreSpiceCLIOSDIError.invalidCatalog("Missing string value") }; selectedValue = .string(stringValue)
        default: throw CoreSpiceCLIOSDIError.invalidCatalog("Unknown parameter type")
        }
        return try .init(name: name, scope: selectedScope, value: selectedValue)
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); scope = try c.decode(String.self, forKey: .scope)
        type = try c.decode(String.self, forKey: .type)
        descriptorIndex = try c.decodeIfPresent(Int.self, forKey: .descriptorIndex)
        isGiven = try c.decodeIfPresent(Bool.self, forKey: .isGiven)
        switch type {
        case "real": realValue = try c.decode(Double.self, forKey: .value); integerValue = nil; stringValue = nil
        case "integer": realValue = nil; integerValue = try c.decode(Int32.self, forKey: .value); stringValue = nil
        case "string": realValue = nil; integerValue = nil; stringValue = try c.decode(String.self, forKey: .value)
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported explicit OSDI parameter type")
        }
        _ = try assignment()
        guard descriptorIndex.map({ $0 >= 0 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .descriptorIndex, in: c, debugDescription: "Invalid descriptor parameter index")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(scope, forKey: .scope); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(descriptorIndex, forKey: .descriptorIndex); try c.encodeIfPresent(isGiven, forKey: .isGiven)
        switch type {
        case "real": try c.encode(realValue, forKey: .value)
        case "integer": try c.encode(integerValue, forKey: .value)
        case "string": try c.encode(stringValue, forKey: .value)
        default: throw CoreSpiceCLIOSDIError.invalidCatalog("Unknown parameter type")
        }
    }
}
