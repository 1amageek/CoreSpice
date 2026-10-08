import CoreSpiceParsedIR

/// Immutable token backing and its concrete payload/slot capacity owners.
struct SPICEOwnedTokens: Sendable {
    let tokens: [SPICEToken.Located]
    let storage: SPICEParseStorage
}
