import CoreSpiceParsedIR

/// Retains actual accounted output slots until the last copied result releases them.
public struct SPICEOwnedNodeVoltages: Sendable {
    public let bindings: SPICEAccountedCollection<SPICENodeVoltageBinding>
    internal init(bindings: SPICEAccountedCollection<SPICENodeVoltageBinding>) { self.bindings = bindings }
}
