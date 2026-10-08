/// Selection authority is provider-owned; the grammar submits this request before acquisition.
public protocol SPICEContextualFileResolver: Sendable {
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument
}
