import CryptoKit
import Foundation

/// Test-only finite-profile admission before any native image or circuit is executed.
package enum OSDIFamilyProfileAdmission {
    package enum Failure: Error { case rejected(String) }

    private indirect enum Value: Decodable, Equatable {
        case object([String: Value]), array([Value]), string(String), number(Double), bool(Bool), null

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try Self.matching(Bool.self, container) { self = .bool(value) }
            else if let value = try Self.matching(String.self, container) { self = .string(value) }
            else if let value = try Self.matching(Double.self, container), value.isFinite { self = .number(value) }
            else if let value = try Self.matching([Value].self, container) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }
        private static func matching<T: Decodable>(_ type: T.Type, _ container: any SingleValueDecodingContainer) throws -> T? {
            do { return try container.decode(type) }
            catch DecodingError.typeMismatch(_, _) { return nil }
        }
        var object: [String: Value] { get throws {
            guard case .object(let value) = self else { throw Failure.rejected("Expected an object") }; return value
        } }
        var array: [Value] { get throws {
            guard case .array(let value) = self else { throw Failure.rejected("Expected an array") }; return value
        } }
        var string: String { get throws {
            guard case .string(let value) = self else { throw Failure.rejected("Expected a string") }; return value
        } }
    }

    package static var authorityURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/OSDIModelQualification/profiles.json")
    }

    /// Selects every required CLI representative from the caller's frozen family profile.
    package static func cliRepresentativeCaseIDs(profile: String, prepared: Bool) throws -> [String] {
        let authority = try decode(boundedRead(authorityURL)).object
        let profiles = try required(authority, "cliRepresentativeCaseIDs").object
        let selection = try required(profiles, profile).object
        let values = try required(selection, prepared ? "prepared" : "executable").array
        let identifiers = try values.map { try $0.string }
        try require(!identifiers.isEmpty && Set(identifiers).count == identifiers.count, "Required CLI representatives")
        return identifiers
    }

    /// Admits the retained latest-SOI analysis references against the frozen DC model/input authority.
    package static func validateLatestSOI101Analysis(_ data: Data) throws {
        let root = authorityURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let authority = try decode(boundedRead(authorityURL)).object
        let families = try required(authority, "families").object
        let specification = try required(families, "SOI-101.0.0").object
        let manifest = try decode(data).object
        try require(manifest["schema"] == .string("corespice.osdi.analysis-manifest.v1"), "Analysis manifest schema")
        let libraries = try required(manifest, "libraries").array
        try require(libraries.count == 1, "Exact latest-SOI analysis library set")
        let library = try libraries[0].object
        try require(library["id"] == specification["libraryID"]
            && library["sha256"] == specification["artifactSHA256"]
            && library["descriptorIndex"] == specification["descriptorIndex"]
            && library["descriptorName"] == specification["descriptorName"], "Latest-SOI qualified image binding")
        let requestBytes = try boundedRead(root.appendingPathComponent(try required(specification, "requestPath").string))
        try require(.string(hash(requestBytes)) == specification["requestSHA256"], "Latest-SOI frozen request bytes")
        let requests = try indexed(required(try decode(requestBytes).object, "cases"))
        let circuit = try required(requests, "soi101-n-dd-loaded")
        let cases = try indexed(required(manifest, "cases"))
        try require(Set(cases.keys) == ["soi101-ac", "soi101-noise", "soi101-transient"], "Required latest-SOI analysis cases")
        for kind in ["ac", "noise", "transient"] {
            let point = try required(cases, "soi101-" + kind).object
            let input = try required(point, "input").object
            let analysis = try required(input, "analysis").object
            let reference = try required(point, "reference").object
            try require(point["family"] == .string("SOI101") && point["kind"] == .string(kind)
                && point["expectedOutcome"] == .string("passed") && input["circuit"] == circuit
                && analysis["kind"] == .string(kind) && reference["kind"] == .string(kind)
                && reference["status"] == .string("passed"), "Latest-SOI exact circuit/analysis reference")
            if kind != "transient" {
                let frequencies = try required(analysis, "frequenciesHz").array
                let referenceFrequencies = try required(reference, "points").array.map { try required($0.object, "frequencyHz") }
                try require(frequencies == referenceFrequencies, "Captured frequency ordering")
                let values = try frequencies.map { value -> Double in
                    guard case .number(let number) = value else { throw Failure.rejected("Frequency must be numeric") }
                    return number
                }
                _ = try decadeSweepEndpoints(values)
            }
        }
    }

    /// The source fixtures emit dec=1 sweeps only when they exactly represent every captured point.
    package static func decadeSweepEndpoints(_ frequencies: [Double]) throws -> (first: Double, last: Double) {
        guard let first = frequencies.first, let last = frequencies.last,
              first.isFinite, first > 0, last.isFinite else { throw Failure.rejected("Invalid frequency endpoints") }
        for index in frequencies.indices.dropFirst() {
            guard frequencies[index].isFinite, frequencies[index] == frequencies[index - 1] * 10 else {
                throw Failure.rejected("Captured frequency sequence cannot be represented by dec=1")
            }
        }
        return (first, last)
    }

    package static func validate(_ data: Data, profile: String = "latest-soi101-v1",
                                 authorityURL: URL = OSDIFamilyProfileAdmission.authorityURL) throws {
        let root = authorityURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let authorityBytes = try boundedRead(authorityURL)
        let authority = try decode(authorityBytes).object
        try require(authority["schema"] == .string("corespice.osdi.family-profile-authority.v1"), "Authority schema")
        let selection = try required(try required(authority, "profiles").object, profile).object
        try require(Set(selection.keys) == ["BULK", "CMG", "IMG", "SOI"], "Required four-family profile")
        let specifications = try required(authority, "families").object
        let manifest = try decode(data).object
        try require(manifest["schema"] == .string("corespice.osdi.dc-manifest.v1") && manifest["status"] == .string("passed"), "Passed DC capture")
        let identity = SHA256.hash(data: authorityBytes).map { String(format: "%02x", $0) }.joined()
        try require(manifest["qualificationProfile"] == .object(["id": .string(profile), "sha256": .string(identity)]), "Exact profile authority")
        try require(manifest["qualificationComplete"] == .bool(true), "Incomplete family qualification")
        let libraries = try indexed(required(manifest, "libraries"))
        let cases = try indexed(required(manifest, "cases"))
        let bindings = try required(manifest, "familyBindings").object
        try require(Set(bindings.keys) == Set(selection.keys), "Missing or unknown family")
        let baselineURL = root.appendingPathComponent(try required(authority, "baselineRequestPath").string)
        let baselineBytes = try boundedRead(baselineURL)
        try require(.string(hash(baselineBytes)) == authority["baselineRequestSHA256"], "Baseline request bytes")
        let baseline = try required(try decode(baselineBytes).object, "cases").array
        try require(.array(try baseline.map { try required($0.object, "id") }) == authority["requiredBaselineCaseIDs"], "Baseline case set")
        var expectedIDs = Set<String>()
        for request in baseline {
            let identifier = try required(request.object, "id").string
            expectedIDs.insert(identifier)
            try require(try cases[identifier]?.object["input"] == request, "Missing or changed baseline request: " + identifier)
        }
        var matrix: [String: Value] = [:]
        for (family, key) in selection {
            let specification = try required(specifications, key.string).object
            let libraryID = try required(specification, "libraryID").string
            let library = try required(libraries, libraryID).object
            try require(library["id"] == .string(libraryID)
                && library["descriptorIndex"] == specification["descriptorIndex"]
                && library["descriptorName"] == specification["descriptorName"], "Family descriptor binding")
            let artifactSHA = try required(library, "sha256").string
            try require(artifactSHA.count == 64 && artifactSHA.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Artifact SHA-256")
            try require(required(specification, "artifactSHA256") == .string(artifactSHA), "Pinned family image")
            let expectedBinding: Value = .object([
                "version": try required(specification, "version"), "library": .object(library),
                "sourceSHA256": try required(specification, "sourceSHA256"),
                "compilerSHA256": try required(specification, "compilerSHA256"),
                "compilerProfileReceiptSHA256": try required(specification, "compilerProfileReceiptSHA256"),
                "requestSHA256": try required(specification, "requestSHA256")])
            try require(bindings[family] == expectedBinding, "Family version/source/compiler/request/library binding")
            let requestsURL = root.appendingPathComponent(try required(specification, "requestPath").string)
            let requestBytes = try boundedRead(requestsURL)
            try require(.string(hash(requestBytes)) == specification["requestSHA256"], "Frozen request bytes")
            let requests = try indexed(required(try decode(requestBytes).object, "cases"))
            let ids = try required(specification, "requiredCaseIDs").array
            let idStrings = try ids.map { try $0.string }
            try require(idStrings.count == Set(idStrings).count, "Duplicate required case")
            for identifier in idStrings {
                expectedIDs.insert(identifier)
                let request = try required(requests, identifier)
                let captured = try required(cases, identifier).object
                try require(captured["input"] == request, "Missing or changed family request: " + identifier)
                if family != "BULK" { try require(captured["family"] == .string(family), "Wrong case family") }
                let input = try request.object
                for device in try required(input, "devices").array {
                    let value = try device.object
                    try require(value["library"] == .string(libraryID) && value["descriptorIndex"] == library["descriptorIndex"], "Case/library mismatch")
                }
                try require(try required(captured, "reference").object["status"] == input["expectedOutcome"], "Independent outcome mismatch")
            }
            matrix[family] = .object(["version": try required(specification, "version"), "status": .string("captured"),
                "caseIDs": .array(ids), "libraryID": .string(libraryID), "librarySHA256": .string(artifactSHA)])
        }
        try require(Set(cases.keys) == expectedIDs, "Unexpected or omitted finite-profile case")
        try require(manifest["familyMatrix"] == .object(matrix), "Stale family matrix")
    }

    private static func boundedRead(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try require(data.count <= 1024 * 1024, "Profile JSON byte limit")
        return data
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func decode(_ data: Data) throws -> Value { try JSONDecoder().decode(Value.self, from: data) }
    private static func required(_ object: [String: Value], _ key: String) throws -> Value {
        guard let value = object[key] else { throw Failure.rejected("Missing " + key) }; return value
    }
    private static func indexed(_ values: Value) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for value in try values.array {
            let key = try required(value.object, "id").string
            try require(result.updateValue(value, forKey: key) == nil, "Duplicate identity: " + key)
        }
        return result
    }
    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure.rejected(reason) }
    }
}
