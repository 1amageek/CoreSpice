import CoreSpiceParsedIR
import CoreSpiceParser

/// Load-local owner registry. Keys are lookup authority, never filesystem search paths.
actor SPICEExactSourceResolver: FileResolver {
    private let request: SPICEExactLoadRequest
    private struct DependencyLookup: Hashable {
        let parent: String
        let path: String
        let kind: SPICESourceDependencyEvent.Kind
        let section: String?
    }
    private let dependencies: [DependencyLookup: String]
    private let expected: [String: SPICEExactSourceBinding]
    private let provider: any SPICEExactSourceProviding
    private let work: any SPICESourceWorkAccounting
    private var captures: [SPICESourceCapture] = []
    private var owners: [String: SPICECheckedSource] = [:]

    init(request: SPICEExactLoadRequest, provider: any SPICEExactSourceProviding,
         work: any SPICESourceWorkAccounting) throws {
        let policy = request.capturePolicy
        guard policy.maximumTotalByteCount > 0, policy.maximumSourceCount > 0,
              policy.maximumPageByteCount > 0, policy.maximumPageByteCount <= policy.maximumTotalByteCount,
              policy.maximumPageByteCount <= UInt64(Int.max), request.configuration.resolveIncludes,
              request.configuration.maxIncludeDepth > 0 else { throw SPICEExactSourceError.invalidPolicy }
        var table: [String: SPICEExactSourceBinding] = [:]
        var total: UInt64 = 0
        for binding in request.expectedSources {
            try work.charge(.retainedElements, units: 1)
            guard !binding.key.isEmpty else { throw SPICEExactSourceError.invalidSourceKey }
            guard table[binding.key] == nil else { throw SPICEExactSourceError.duplicateSource(binding.key) }
            guard binding.reference.byteCount <= policy.maximumTotalByteCount - total else {
                throw SPICESourceCaptureError.totalByteLimitExceeded(limit: policy.maximumTotalByteCount,
                    requested: binding.reference.byteCount)
            }
            total += binding.reference.byteCount
            table[binding.key] = binding
        }
        guard UInt64(table.count) <= policy.maximumSourceCount else {
            throw SPICESourceCaptureError.sourceCountLimitExceeded(limit: policy.maximumSourceCount)
        }
        guard table[request.rootKey] != nil else { throw SPICEExactSourceError.undeclaredSource(request.rootKey) }
        var dependencies: [DependencyLookup: String] = [:]
        for dependency in request.expectedDependencies {
            try work.charge(.retainedElements, units: 1)
            guard table[dependency.parentKey] != nil else {
                throw SPICEExactSourceError.undeclaredSource(dependency.parentKey)
            }
            guard table[dependency.childKey] != nil else {
                throw SPICEExactSourceError.undeclaredSource(dependency.childKey)
            }
            let lookup = DependencyLookup(parent: dependency.parentKey, path: dependency.path,
                kind: dependency.kind, section: dependency.kind == .include ? nil : dependency.selectedSection)
            if let existing = dependencies[lookup], existing != dependency.childKey {
                throw SPICEExactSourceError.graphMismatch
            }
            dependencies[lookup] = dependency.childKey
        }
        self.request = request
        self.expected = table
        self.dependencies = dependencies
        self.provider = provider
        self.work = work
    }

    func readFile(at key: String) async throws -> SPICESourceDocument {
        try work.checkCancellation()
        if let owner = owners[key] { return document(owner) }
        guard let binding = expected[key] else { throw SPICEExactSourceError.undeclaredSource(key) }
        try work.charge(.sourceBytes, units: binding.reference.byteCount)
        let owner = try await provider.source(for: binding, work: work,
            maximumPageByteCount: request.capturePolicy.maximumPageByteCount)
        guard owner.binding == binding else { throw SPICEExactSourceError.sourceDrift(key) }
        try work.checkCancellation()
        owners[key] = owner
        captures.append(SPICESourceCapture(captureID: key, artifactID: binding.reference.id,
            resolvedPath: key, bytes: owner.bytes, text: owner.text))
        return document(owner)
    }

    func resolveInclude(path: String, relativeTo: String?) async throws -> SPICESourceDocument {
        try await resolve(path: path, section: nil, kind: .include, parent: relativeTo)
    }

    func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> SPICESourceDocument {
        let full = try await resolve(path: path, section: section, kind: .externalLibrary, parent: relativeTo)
        return try full.selectingLibrarySection(section, work: work)
    }

    private func resolve(path: String, section: String?, kind: SPICESourceDependencyEvent.Kind,
                         parent: String?) async throws -> SPICESourceDocument {
        guard let parent else { throw SPICEExactSourceError.invalidSourceKey }
        let lookup = DependencyLookup(parent: parent, path: path, kind: kind,
            section: kind == .include ? nil : section)
        guard let key = dependencies[lookup] else {
            throw SPICEExactSourceError.undeclaredDependency(parent: parent, path: path)
        }
        return try await readFile(at: key)
    }

    private func document(_ owner: SPICECheckedSource) -> SPICESourceDocument {
        SPICESourceDocument(text: owner.text, resolvedPath: owner.binding.key, captureID: owner.binding.key)
    }

    func verify(events: [SPICESourceDependencyEvent]) throws {
        guard events.count == request.expectedDependencies.count else { throw SPICEExactSourceError.graphMismatch }
        for (event, expected) in zip(events, request.expectedDependencies) {
            guard event.parentCaptureID == expected.parentKey, event.childCaptureID == expected.childKey,
                  event.kind == expected.kind, event.path == expected.path,
                  event.selectedSection == expected.selectedSection,
                  event.location?.line == expected.line, event.location?.column == expected.column,
                  event.preprocessingContext == expected.preprocessingContext else {
                throw SPICEExactSourceError.graphMismatch
            }
        }
        for key in self.expected.keys where owners[key] == nil { throw SPICEExactSourceError.unusedSource(key) }
    }

    func capturedSources() -> [SPICESourceCapture] { captures }
    func sourceBindings() -> [SPICEExactSourceBinding] { captures.compactMap { expected[$0.captureID] } }
}
