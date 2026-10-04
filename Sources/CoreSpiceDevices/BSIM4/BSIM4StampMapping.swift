/// Bind-time CSR positions for every padded original matrix slot.
struct BSIM4StampMapping: Sendable {
    private var block0 = SIMD64<Int>(repeating: -1)
    private var block1 = SIMD64<Int>(repeating: -1)
    private var block2 = SIMD64<Int>(repeating: -1)
    private var block3 = SIMD64<Int>(repeating: -1)
    init() {}
    subscript(index: Int) -> Int {
        precondition((0..<256).contains(index))
        switch index / 64 {
        case 0: return block0[index % 64]
        case 1: return block1[index % 64]
        case 2: return block2[index % 64]
        default: return block3[index % 64]
        }
    }
    mutating func set(_ index: Int, _ value: Int) {
        precondition((0..<256).contains(index))
        switch index / 64 {
        case 0: block0[index % 64] = value
        case 1: block1[index % 64] = value
        case 2: block2[index % 64] = value
        default: block3[index % 64] = value
        }
    }
}
