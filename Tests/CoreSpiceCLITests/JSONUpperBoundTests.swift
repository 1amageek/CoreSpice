import CoreSpiceIO
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("CLI JSON grammar capacity", .timeLimit(.minutes(1)))
struct JSONUpperBoundTests {
    private func resources() throws -> SPICESimulationResources {
        let liveBytes: UInt64 = 134_217_728
        let temporaryBytes: UInt64 = 67_108_864
        let workUnits: UInt64 = 1_000_000_000
        let hashedBytes: UInt64 = 67_108_864
        return try SPICESimulationResources(maximumLiveBytes: liveBytes, maximumTemporaryBytes: temporaryBytes,
            maximumWorkUnits: workUnits, maximumHashedBytes: hashedBytes)
    }
    /// Uses the independent Foundation encoder with the actual production formatting contract.
    private func compare<T: Encodable>(_ value: T) throws -> (upper: UInt64, actual: UInt64) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let actual = UInt64(try encoder.encode(value).count)
        let upper = try CoreSpiceCLIJSONUpperBound.count(value, maximumBytes: 16 * 1024 * 1024, resources: resources())
        #expect(actual <= upper)
        return (upper, actual)
    }

    private struct GenericValue<T: Encodable>: Encodable {
        let value: T
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
    private indirect enum Nest: Encodable {
        case text(String)
        case array([Nest])
        func encode(to encoder: any Encoder) throws {
            switch self {
            case .text(let text): var c = encoder.singleValueContainer(); try c.encode(text)
            case .array(let values): var c = encoder.unkeyedContainer(); for value in values { try c.encode(value) }
            }
        }
    }
    private struct Parameter: Encodable {
        let name: String
        let scope: String
        let type: String
        let descriptorIndex: Int
        let isGiven: Bool
        let value: Double
    }

    @Test func stringsControlEscapingUnicodeAndGenericForwardingStayBounded() throws {
        var controls = ""
        for code in 0...31 { controls.unicodeScalars.append(Unicode.Scalar(code)!) }
        let strings = ["", "plain ASCII", "quote\" backslash\\ slash/", controls,
            "日本語 🧪 café", "line\u{2028}paragraph\u{2029}", String(repeating: "a/\\\"", count: 4096)]
        _ = try compare(strings)
        _ = try compare(Dictionary(uniqueKeysWithValues: (0..<1024).map { ("field_\($0)", "") }))
        _ = try compare(Dictionary(uniqueKeysWithValues: strings.enumerated().map { (String($0.offset) + $0.element, $0.element) }))
        _ = try compare(GenericValue(value: GenericValue(value: strings)))
        _ = try compare(GenericValue(value: Optional<[String]>.some(strings)))
        _ = try compare(GenericValue(value: Optional<[String]>.none))
    }

    @Test func emptyDeepAndLargeContainersUseJSONDepthOnce() throws {
        _ = try compare([String: [String: Int]]())
        _ = try compare([[String]]())
        _ = try compare([String: [String: [Int]]](dictionaryLiteral: ("empty", [:]), ("arrays", ["empty": []])))
        var nested = Nest.text("leaf")
        for _ in 0..<72 { nested = .array([nested, .array([])]) }
        _ = try compare(GenericValue(value: nested))
        let values = (0..<2000).map { Parameter(name: "parameter_\($0)", scope: "model", type: "real",
            descriptorIndex: $0, isGiven: $0.isMultiple(of: 2), value: Double($0) * 0.125) }
        let sizes = try compare(values)
        // Parameter-rich records must not be rejected by repeated container/field safety padding.
        #expect(sizes.upper < sizes.actual * 3)
    }

    @Test func allFiniteNumericExtremesAndScalarTokensStayBounded() throws {
        _ = try compare([Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
            Double.leastNonzeroMagnitude, -Double.leastNonzeroMagnitude, Double.leastNormalMagnitude, -0.0, 0, 1])
        _ = try compare([Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
            Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude, -0.0, 0, 1])
        _ = try compare([Int.min, Int.max])
        _ = try compare([Int8.min, Int8.max])
        _ = try compare([Int16.min, Int16.max])
        _ = try compare([Int32.min, Int32.max])
        _ = try compare([Int64.min, Int64.max])
        _ = try compare([UInt.min, UInt.max])
        _ = try compare([UInt8.min, UInt8.max])
        _ = try compare([UInt16.min, UInt16.max])
        _ = try compare([UInt32.min, UInt32.max])
        _ = try compare([UInt64.min, UInt64.max])
        _ = try compare([true, false])
        _ = try compare([Int?](arrayLiteral: nil, 1))
    }

    private struct ExplicitContainers: Encodable {
        private enum Key: String, CodingKey { case nested, values, inherited, scalar }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            var nested = c.nestedContainer(keyedBy: Key.self, forKey: .nested)
            try nested.encode("value", forKey: .scalar)
            var list = nested.nestedUnkeyedContainer(forKey: .values)
            try list.encodeNil()
            var member = list.nestedContainer(keyedBy: Key.self)
            try member.encode(1, forKey: .scalar)
            var array = list.nestedUnkeyedContainer()
            try array.encode("array")
            var scalar = list.superEncoder().singleValueContainer()
            try scalar.encode("super element")
            var inherited = c.superEncoder(forKey: .inherited).container(keyedBy: Key.self)
            try inherited.encode(false, forKey: .scalar)
            var implicit = c.superEncoder().unkeyedContainer()
            try implicit.encode("implicit super")
        }
    }
    @Test func explicitNestedAndSuperEncodersPreserveStructuralAllowance() throws {
        _ = try compare(ExplicitContainers())
        _ = try compare(GenericValue(value: ExplicitContainers()))
        _ = try compare([ExplicitContainers(), ExplicitContainers()])
    }

    @Test func selectedCeilingStillRefusesBeforeEncoding() throws {
        let value = ["key": ["value", "other"]]
        let owner = try resources()
        let upper = try CoreSpiceCLIJSONUpperBound.count(value, maximumBytes: 1024 * 1024, resources: owner)
        #expect(upper > 0)
        #expect(throws: (any Error).self) {
            try CoreSpiceCLIJSONUpperBound.count(value, maximumBytes: upper - 1, resources: owner)
        }
    }
}
