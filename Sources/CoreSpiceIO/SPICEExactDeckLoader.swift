import CircuiteFoundation
import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE

/// Exact intake composes checked source owners with the ordinary parser implementation.
public struct SPICEExactDeckLoader: SPICEDeckSourceLoading {
    public init() {}

    public func load(request: SPICEExactLoadRequest, provider: any SPICEExactSourceProviding,
                     work: any SPICESourceWorkAccounting) async throws -> LoadedSPICEDeck {
        let budget = try SPICEBoundedSourceWork(limits: request.workLimits, upstream: work)
        let resolver = try SPICEExactSourceResolver(request: request, provider: provider, work: budget)
        let root = try await resolver.readFile(at: request.rootKey)
        let selected = try root.selectingLibrarySection(request.selectedSection, work: budget)
        let result = try await SPICEParser().parseChecked(document: selected,
            configuration: request.configuration, fileResolver: resolver,
            work: budget, initialParameters: request.initialParameters)
        let netlist = try result.get()
        try await resolver.verify(events: netlist.dependencyEvents)
        let coverage = SPICEDeckCoverageReport.generate(from: result)
        let blocked = coverage.globalExecutionBlockers
        guard blocked.isEmpty else { throw SPICEDeckLoadError.blockedExecutionIntent(items: blocked) }
        try budget.checkCancellation()
        return LoadedSPICEDeck(source: root.text, netlist: netlist, coverage: coverage,
            captures: await resolver.capturedSources(), capturePolicy: request.capturePolicy,
            exactRequest: request, exactSources: await resolver.sourceBindings(),
            sourceWorkConsumption: budget.consumption)
    }
}
