import CoreSpiceParsedIR

/// Immutable local accounting bridge; owns no counters or shared mutation.
internal struct SPICENodeVoltageWork {
    let resources: any SPICESourceResourceAccounting
    func check() throws(SPICENodeVoltageResolutionError) {
        do { try resources.checkCancellation() } catch { throw .resource(cause: error) }
    }
    func step() throws(SPICENodeVoltageResolutionError) {
        do { try resources.checkCancellation(); try resources.charge(.tokens, units: 1) }
        catch { throw .resource(cause: error) }
    }
    func equalASCII(_ lhs: String, _ rhs: String) throws(SPICENodeVoltageResolutionError) -> Bool {
        // Validate both complete names even when a comparison could return early.
        try validateASCII(lhs); try validateASCII(rhs)
        var left = lhs.utf8.makeIterator(), right = rhs.utf8.makeIterator()
        while true {
            try step()
            let a = left.next(), b = right.next()
            if a == nil || b == nil { return a == nil && b == nil }
            func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
            if a.map(lower) != b.map(lower) { return false }
        }
    }
    private func validateASCII(_ name: String) throws(SPICENodeVoltageResolutionError) {
        for byte in name.utf8 {
            try step()
            // FIXME(INCOMPLETE_IMPLEMENTATION): Bounded node binding reaches this refusal for Unicode names. A cooperative Unicode case-normalization backend must own all work and copied storage before success is supported.
            guard byte < 128 else { throw .unsupportedCapability(.unicodeNodeName) }
        }
    }

}
