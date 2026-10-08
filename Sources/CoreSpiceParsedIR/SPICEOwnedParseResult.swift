/// Checked grammar publication with immutable retained source and derived storage.
public struct SPICEOwnedParseResult: Sendable {
    /// Retain this result while using its raw netlist in a bounded operation.
    public let netlist: ParsedNetlist
    private let retainedOwner: any Sendable

    package init(netlist: ParsedNetlist, retaining owner: any Sendable) {
        self.netlist = netlist
        self.retainedOwner = owner
    }
}
