import CoreSpiceParsedIR

/// Bounded Core-owned textual projection of an existing expression value.
public protocol SPICEExpressionFormatting: Sendable {
    func format(expression: ParsedExpression,
                resources: any SPICESourceResourceAccounting) throws -> SPICEOwnedExpressionText
}
