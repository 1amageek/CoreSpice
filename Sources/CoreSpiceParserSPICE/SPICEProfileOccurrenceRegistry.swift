import CoreSpiceParsedIR
import CoreSpiceParser

/// One serial grammar traversal shares occurrence admission across nested awaits.
actor SPICEProfileOccurrenceRegistry {
    private let resources: any SPICESourceResourceAccounting
    private let metadata: SPICESourceStorageReservation
    private var occurrences = SPICEAccountedCollection<SPICEParseOccurrenceID>(storageKind: .temporaryBytes)

    static func admit(resources: any SPICESourceResourceAccounting) throws -> SPICEProfileOccurrenceRegistry {
        let receipt = try SPICESourceCapacity.reserve(of:
            ((any SPICESourceResourceAccounting), SPICESourceStorageReservation,
             SPICEAccountedCollection<SPICEParseOccurrenceID>).self,
            capacity: 1, kind: .temporaryBytes, resources: resources)
        return SPICEProfileOccurrenceRegistry(resources: resources, metadata: receipt)
    }

    private init(resources: any SPICESourceResourceAccounting, metadata: SPICESourceStorageReservation) {
        self.resources = resources; self.metadata = metadata
    }

    func insert(_ occurrence: SPICEParseOccurrenceID) throws {
        for prior in occurrences {
            try resources.checkCancellation()
            try resources.charge(.tokens, units: 1)
            guard prior != occurrence else { throw SPICEBoundedSourceError.invalidSourceContext }
        }
        try occurrences.append(occurrence, resources: resources)
    }
}
