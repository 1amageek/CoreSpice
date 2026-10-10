/// CoreSpice XorShift64StarV1. Zero has a fixed nonzero state, never a clock seed.
package struct MOSCoreRandom {
    package static let version = "CoreSpice.XorShift64Star.v1"
    private var state: UInt64
    package init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    package mutating func next() -> Double {
        var x = state
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27
        state = x
        let bits = (x &* 0x2545F4914F6CDD1D) >> 11
        return Double(bits) / 9_007_199_254_740_992.0
    }
}
