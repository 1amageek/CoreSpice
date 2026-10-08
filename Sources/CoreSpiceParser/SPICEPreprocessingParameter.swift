/// Caller-owned input; checked environments retain copied/normalized entries.
public struct SPICEPreprocessingParameter: Sendable, Equatable {
    public let name: String
    public let expression: String
    private let nameOwner: SPICEAccountedText?
    private let expressionOwner: SPICEAccountedText?

    public init(name: String, expression: String) {
        self.name = name; self.expression = expression; nameOwner = nil; expressionOwner = nil
    }
    internal init(name: SPICEAccountedText, expression: SPICEAccountedText) {
        self.name = name.text; self.expression = expression.text
        nameOwner = name; expressionOwner = expression
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.expression == rhs.expression
    }
}
