import CoreSpiceParsedIR

/// Exact caller-owned source intake using the production SPICE grammar and coverage gate.
public protocol SPICEDeckSourceLoading: Sendable {
    func load(request: SPICEExactLoadRequest, provider: any SPICEExactSourceProviding,
              work: any SPICESourceWorkAccounting) async throws -> LoadedSPICEDeck
}
