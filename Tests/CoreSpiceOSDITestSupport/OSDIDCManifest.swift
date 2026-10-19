import Foundation
import OSDIContracts

package struct OSDIDCManifest: Decodable, Sendable {
    package let libraries: [Library]
    package let cases: [Case]
    package struct Library: Decodable, Sendable {
        package let id: String
        package let path: String
        package let sha256: String
        package let descriptorIndex: Int
        package let descriptorName: String
        package init(id: String, path: String, sha256: String, descriptorIndex: Int, descriptorName: String) {
            self.id = id; self.path = path; self.sha256 = sha256
            self.descriptorIndex = descriptorIndex; self.descriptorName = descriptorName
        }
    }
    package struct Case: Decodable, Sendable {
        package let id: String
        package let input: Input
        package let reference: Reference
        package let validationBaseCommand: [String]
    }
    package struct Input: Decodable, Sendable {
        package let devices: [Device]
        package let resistors: [Linear]
        package let voltageSources: [Linear]
        package let currentSources: [Linear]
        package let initialUnknowns: [String: Double]
        package let policy: Policy
        package let expectedOutcome: String
    }
    package struct Device: Decodable, Sendable {
        package let id: String
        package let library: String
        package let descriptorIndex: Int
        package let temperatureKelvin: Double
        package let connectedTerminalCount: Int
        package let terminals: [String: String]
        package let parameters: [Parameter]
        package let previousState: [Double]
    }
    package struct Parameter: Decodable, Sendable {
        package let scope: String
        package let name: String
        package let value: Value
        package struct Value: Decodable, Sendable { package let kind: String; package let real: Double?; package let integer: Int32?; package let string: String? }
        package func assignment() throws -> OSDIParameterAssignment {
            let converted: OSDIParameterValue
            switch value.kind {
            case "real": guard let real = value.real else { throw Failure.invalidManifest }; converted = .real(real)
            case "integer": guard let integer = value.integer else { throw Failure.invalidManifest }; converted = .integer(integer)
            case "string": guard let string = value.string else { throw Failure.invalidManifest }; converted = .string(string)
            default: throw Failure.invalidManifest
            }
            let parameterScope: OSDIParameterScope
            switch scope {
            case "model": parameterScope = .model
            case "instance": parameterScope = .instance
            default: throw Failure.invalidManifest
            }
            return try OSDIParameterAssignment(name: name, scope: parameterScope, value: converted)
        }
    }
    package struct Linear: Decodable, Sendable { package let id: String; package let positive: String; package let negative: String; package let value: Double }
    package struct Policy: Decodable, Sendable {
        package let unknownAbsoluteTolerances: [String: Double]
        package let equationAbsoluteTolerances: [String: Double]
        package let relativeTolerance: Double
        package let maximumIterations: Int
    }
    package struct Reference: Decodable, Sendable {
        package let status: String
        package let unknowns: [Unknown]?
        package let candidateUnknowns: [Unknown]?
        package let devices: [PreparedDevice]
    }
    package struct Unknown: Decodable, Sendable { package let id: String; package let unit: String; package let residualUnit: String; package let value: Double }
    package struct PreparedDevice: Decodable, Sendable { package let id: String; package let rawNodes: [RawNode] }
    package struct RawNode: Decodable, Sendable { package let index: Int; package let name: String; package let unknownID: String?; package let unit: String; package let residualUnit: String; package let isFlow: Bool }
    package enum Failure: Error { case invalidManifest, physicalResidual(row: Int, value: Double), missingMapping(String), oracleFailure(String) }
}
