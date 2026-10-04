/// Fixed 16-by-16 padded storage, composed from standard SIMD64 blocks.
public struct BSIM4Matrix: Sendable {
    private var block0 = SIMD64<Double>(repeating: 0)
    private var block1 = SIMD64<Double>(repeating: 0)
    private var block2 = SIMD64<Double>(repeating: 0)
    private var block3 = SIMD64<Double>(repeating: 0)
    init() {}
    public subscript(index: Int) -> Double {
        precondition((0..<256).contains(index))
        switch index / 64 {
        case 0: return block0[index % 64]
        case 1: return block1[index % 64]
        case 2: return block2[index % 64]
        default: return block3[index % 64]
        }
    }
    mutating func set(_ index: Int, _ value: Double) {
        precondition((0..<256).contains(index))
        switch index / 64 {
        case 0: block0[index % 64] = value
        case 1: block1[index % 64] = value
        case 2: block2[index % 64] = value
        default: block3[index % 64] = value
        }
    }
}
