/// Keep this value while using its raw String in a bounded operation.
public struct SPICEOwnedExpressionText: Sendable {
    public let text: String
    private let retainedOwner: any Sendable

    internal init(text: String, retaining owner: any Sendable) {
        self.text = text; self.retainedOwner = owner
    }
}
