import CoreSpiceIO

/// Reuses the exact captured input graph without reopening original paths.
struct CoreSpiceCLICapturedSourceCatalog {
    let sources: [SPICECheckedSource]
    let routes: [SPICESourceCatalogRoute]

    init(_ deck: LoadedSPICEDeck, resources: SPICESimulationResources) throws {
        var admitted: [SPICECheckedSource] = []
        let keys = Set(deck.captures.map(\.captureID))
        let referencer = try CoreSpiceCLIArtifactReferencer()
        for capture in deck.captures {
            try resources.checkCancellation()
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(capture.bytes.count))
            let bytes = Array(capture.bytes)
            let reference = referencer.input(capture: capture, kind: .netlist, format: .spice)
            admitted.append(try .admit(binding: .init(key: capture.captureID, reference: reference),
                bytes: bytes.span, resources: resources, maximumPageByteCount: 4096))
            withExtendedLifetime(scratch) { }
        }
        routes = try deck.dependencyEvents.map { event in
            guard let parent = event.parentCaptureID, let child = event.childCaptureID,
                  keys.contains(parent), keys.contains(child) else {
                throw CoreSpiceCLICaseError.incompleteOutput("Captured source route is incomplete")
            }
            return .init(parentKey: parent, childKey: child, literalRoute: event.path,
                kind: event.kind, selectedSection: event.selectedSection)
        }
        sources = admitted
    }
}
