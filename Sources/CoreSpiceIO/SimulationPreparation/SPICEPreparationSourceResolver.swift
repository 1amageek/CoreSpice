import CoreSpiceParsedIR
import CoreSpiceParser

internal actor SPICEPreparationSourceResolver: SPICEContextualFileResolver {
    private let request: SPICESimulationPreparationRequest
    private let resources: any SPICESourceResourceAccounting
    private var sources: [SPICECheckedSource]
    private var occurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>
    private var nextOccurrence: UInt64 = 1
    init(request: SPICESimulationPreparationRequest, resources: any SPICESourceResourceAccounting) throws {
        self.request = request; self.resources = resources; sources = [request.root]
        var occurrences = SPICEAccountedCollection<SPICESimulationSourceOccurrence>(storageKind: .liveOwnedBytes)
        try occurrences.append(.init(source: request.root, occurrenceID: .init(0), parentOccurrenceID: nil,
            statementByteOffset: nil, statementOrdinal: nil, kind: nil, parentSection: nil,
            selectedSection: nil, environment: request.environment), resources: resources)
        self.occurrences = occurrences
    }
    func resolve(_ dependency: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        try resources.checkCancellation()
        var selectedKey: String?
        for route in request.routes {
            try resources.charge(.retainedElements, units: 1)
            if route.parentKey == dependency.parentSourceKey,
               route.literalRoute == dependency.literalRoute, route.kind == dependency.kind,
               (route.kind == .include || route.selectedSection == dependency.requestedChildSection) {
                if let selectedKey, selectedKey != route.childKey { throw SPICEExactSourceError.graphMismatch }
                selectedKey = route.childKey
            }
        }
        guard let key = selectedKey else {
            throw SPICEExactSourceError.undeclaredDependency(parent: dependency.parentSourceKey, path: dependency.literalRoute)
        }
        guard let binding = request.catalog.first(where: { $0.key == key }) else {
            throw SPICEExactSourceError.undeclaredSource(key)
        }
        let source: SPICECheckedSource
        if let prior = sources.first(where: { $0.binding.key == key }) { source = prior }
        else {
            source = try await request.provider.source(for: binding, work: resources,
                                                       maximumPageByteCount: request.limits.maximumPageByteCount)
            guard source.binding == binding, source.isInvocationAccounted else {
                throw SPICEExactSourceError.sourceDrift(key)
            }
            try resources.charge(.retainedElements, units: 1)
            sources.append(source)
        }
        guard occurrences.count < request.limits.maximumElements else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Source occurrence ceiling")
        }
        let occurrence = nextOccurrence
        let (next, overflow) = nextOccurrence.addingReportingOverflow(1)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        nextOccurrence = next
        let document = try source.document(expectedBinding: binding, occurrenceID: .init(occurrence), resolvedPath: key)
        let selected = try document.selectingLibrarySection(dependency.requestedChildSection, resources: resources)
        try occurrences.append(.init(source: source, occurrenceID: .init(occurrence),
            parentOccurrenceID: dependency.parentOccurrenceID, statementByteOffset: dependency.statementByteOffset,
            statementOrdinal: dependency.statementOrdinal, kind: dependency.kind,
            parentSection: dependency.parentSection, selectedSection: selected.librarySection,
            environment: dependency.environment), resources: resources)
        return selected
    }
    func actualOccurrences() -> SPICEAccountedCollection<SPICESimulationSourceOccurrence> { occurrences }
    func capturedSources() -> [SPICECheckedSource] { sources }
}
