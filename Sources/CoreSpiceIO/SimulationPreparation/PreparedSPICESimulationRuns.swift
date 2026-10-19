import CircuiteFoundation
import CoreSpiceParsedIR

/// Retains one captured graph and bounded case selections, preparing numerical inputs on demand.
public struct PreparedSPICESimulationRuns: Sendable {
    public let selections: [SPICESimulationRunSelection]
    public let sourceInputIdentity: ContentDigest
    private let request: SPICESimulationPreparationRequest
    private let parsed: SPICEOwnedParseResult
    private let sources: [SPICECheckedSource]
    private let occurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>
    private let resources: any SPICESourceResourceAccounting
    private let reservation: SPICESourceStorageReservation

    internal init(request: SPICESimulationPreparationRequest, parsed: SPICEOwnedParseResult,
                  sources: [SPICECheckedSource], occurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>,
                  selections: [SPICESimulationRunSelection], sourceInputIdentity: ContentDigest,
                  resources: any SPICESourceResourceAccounting, reservation: SPICESourceStorageReservation) {
        self.request = request; self.parsed = parsed; self.sources = sources; self.occurrences = occurrences
        self.selections = selections; self.sourceInputIdentity = sourceInputIdentity
        self.resources = resources; self.reservation = reservation
    }

    public func prepareRun(at index: Int) throws(SPICESimulationPreparationError) -> PreparedSPICESimulation {
        guard selections.indices.contains(index) else { throw .invalidPolicy }
        return try SPICESimulationPreparer().prepareRun(request: request, parsed: parsed, sources: sources,
            occurrences: occurrences, selection: selections[index], resources: resources)
    }
}
