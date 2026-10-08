import CoreSpiceParsedIR

/// Uses the same formatter and managed storage as contextual parsing.
public struct SPICEExpressionFormatter: SPICEExpressionFormatting {
    public init() {}

    public func format(expression: ParsedExpression,
                       resources: any SPICESourceResourceAccounting) throws -> SPICEOwnedExpressionText {
        try resources.checkCancellation()
        var storage = SPICEParseStorage(resources: resources)
        let text = try SPICEAccountedExpressionFormatting.format(expression, storage: &storage)
        let owner = try storage.immutableOwner()
        try resources.checkCancellation()
        return SPICEOwnedExpressionText(text: text, retaining: owner)
    }
}
