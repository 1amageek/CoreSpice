/// Kind of SPICE conditional directive captured as deck preprocessing evidence.
public enum SPICEConditionalDirectiveKind: String, Sendable, Hashable, Codable {
    case ifStatement = "if"
    case elseIf = "elseif"
    case elseIfAlias = "elif"
    case elseStatement = "else"
    case endIf = "endif"
}
