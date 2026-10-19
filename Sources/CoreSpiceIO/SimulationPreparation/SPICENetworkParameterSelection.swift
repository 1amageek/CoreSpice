import CoreSpiceAnalysis

/// Explicit network intent for exactly one source AC directive selected by analysisIndex.
public struct SPICENetworkParameterSelection: Sendable {
    public let ports: [NetworkPort]
    public let limits: NetworkParameterLimits

    public init(ports: [NetworkPort], limits: NetworkParameterLimits) {
        self.ports = ports; self.limits = limits
    }
}
