import CoreSpiceCompile

/// One synchronous exclusive flat pool. No limb view or mutable pointer escapes.
final class ExactLimbPool {
    private var words: [UInt64]
    private var lengths: [Int]
    private var negative: [Bool]
    let width: Int
    let bitLimit: Int
    private let control: any LinearSolverExecutionControlling
    private let lease: any Sendable
    private var credit = 0

    init(slots: Int, metadataBytes: Int, limits: ExactRowAlgebra.Limits,
         control: any LinearSolverExecutionControlling) throws {
        width = limits.maximumIntegerBits / 64 + (limits.maximumIntegerBits % 64 == 0 ? 0 : 1)
        bitLimit = limits.maximumIntegerBits; self.control = control
        let capacity = try TransientExecutionBudget.multiply(slots, width, "exact pool words")
        let flags = try TransientExecutionBudget.multiply(slots, MemoryLayout<Int>.stride + MemoryLayout<Bool>.stride, "exact pool metadata")
        let bytes = try TransientExecutionBudget.add(TransientExecutionBudget.multiply(capacity, 8, "exact pool bytes"),
            TransientExecutionBudget.add(flags, metadataBytes, "exact metadata"), "exact workspace")
        guard bytes <= limits.maximumWorkspaceBytes else { throw ExactRowAlgebra.Failure.workspaceLimit }
        lease = try control.reserveStorage(byteCount: bytes)
        let metadataInitializations = try TransientExecutionBudget.multiply(slots, 2, "exact parallel pool initialization")
        try control.checkpoint(workUnits: TransientExecutionBudget.add(capacity, metadataInitializations, "exact initialization work"))
        words = [UInt64](repeating: 0, count: capacity)
        lengths = [Int](repeating: 0, count: slots); negative = [Bool](repeating: false, count: slots)
        try control.checkpoint(workUnits: 0)
    }
    func tick() throws {
        // Credits are preadmitted, operation-local and never refunded or reused by
        // a later operation. At most 255 unused units remain after the final poll.
        if credit == 0 { try control.checkpoint(workUnits: 256); credit = 256 }
        credit -= 1
    }
    func admitInitialization(_ count: Int) throws {
        // Array initialization is a distinct admitted library operation. Existing
        // limb-loop credits cannot pay for newly allocated destination elements.
        try control.checkpoint(workUnits: count)
    }
    func isZero(_ a: Int) -> Bool { lengths[a] == 0 }
    func isNegative(_ a: Int) -> Bool { negative[a] }
    func negate(_ a: Int) { if !isZero(a) { negative[a].toggle() } }
    func zero(_ out: Int) throws {
        try tick()
        for j in 0..<lengths[out] { try tick(); words[out * width + j] = 0 }
        lengths[out] = 0; negative[out] = false
    }
    func one(_ out: Int) throws { try zero(out); try tick(); words[out * width] = 1; lengths[out] = 1 }
    func copy(_ out: Int, _ a: Int) throws {
        try tick()
        if out == a { return }
        try zero(out)
        for j in 0..<lengths[a] { try tick(); words[out * width + j] = words[a * width + j] }
        lengths[out] = lengths[a]; negative[out] = negative[a]
    }
    private func finish(_ out: Int, count: Int, sign: Bool) throws {
        var count = count
        while count > 0 { try tick(); if words[out * width + count - 1] != 0 { break }; count -= 1 }
        lengths[out] = count; negative[out] = count > 0 && sign
        if count > 0 {
            let high = words[out * width + count - 1]
            let bits = (count - 1) * 64 + 64 - high.leadingZeroBitCount
            guard bits <= bitLimit else { throw ExactRowAlgebra.Failure.bitLimit }
        }
    }
    func load(_ out: Int, _ value: ExactRowAlgebra.Scalar, clearingPower: UInt64) throws {
        guard value.denominatorPower <= clearingPower else { throw ExactRowAlgebra.Failure.invalidInput }
        let shift = clearingPower - value.denominatorPower
        guard shift <= UInt64(bitLimit), let offset = Int(exactly: shift) else { throw ExactRowAlgebra.Failure.bitLimit }
        try zero(out)
        if value.words.isEmpty { return }
        let whole = offset / 64, part = offset % 64
        for j in value.words.indices {
            try tick(); let at = j + whole
            guard at < width else { throw ExactRowAlgebra.Failure.bitLimit }
            words[out * width + at] |= value.words[j] << part
            if part != 0 {
                let carry = value.words[j] >> (64 - part)
                if carry != 0 {
                    guard at + 1 < width else { throw ExactRowAlgebra.Failure.bitLimit }
                    words[out * width + at + 1] |= carry
                }
            }
        }
        try finish(out, count: min(width, value.words.count + whole + (part == 0 ? 0 : 1)), sign: value.negative)
    }
    func shift(_ out: Int, _ a: Int, power: UInt64) throws {
        precondition(out != a)
        guard power <= UInt64(bitLimit), let shift = Int(exactly: power) else { throw ExactRowAlgebra.Failure.bitLimit }
        try zero(out)
        if isZero(a) { return }
        let whole = shift / 64, part = shift % 64
        for j in 0..<lengths[a] {
            try tick(); let at = j + whole, value = words[a * width + j]
            guard at < width else { throw ExactRowAlgebra.Failure.bitLimit }
            words[out * width + at] |= value << part
            if part != 0, value >> (64 - part) != 0 {
                guard at + 1 < width else { throw ExactRowAlgebra.Failure.bitLimit }
                words[out * width + at + 1] |= value >> (64 - part)
            }
        }
        try finish(out, count: min(width, lengths[a] + whole + (part == 0 ? 0 : 1)), sign: negative[a])
    }
    private func compare(_ a: Int, _ b: Int) throws -> Int {
        if lengths[a] != lengths[b] { return lengths[a] < lengths[b] ? -1 : 1 }
        for j in (0..<lengths[a]).reversed() {
            try tick(); let x = words[a * width + j], y = words[b * width + j]
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
    func equal(_ a: Int, _ b: Int) throws -> Bool { try negative[a] == negative[b] && compare(a, b) == 0 }
    func add(_ out: Int, _ a: Int, _ b: Int, subtract: Bool = false) throws {
        precondition(out != a && out != b)
        let bSign = !isZero(b) && (negative[b] != subtract)
        if negative[a] != bSign {
            let order = try compare(a, b)
            if order == 0 { try zero(out); return }
            let large = order > 0 ? a : b, small = order > 0 ? b : a
            try zero(out); var borrow: UInt64 = 0
            for j in 0..<lengths[large] {
                try tick()
                let x = words[large * width + j], y = j < lengths[small] ? words[small * width + j] : 0
                let first = x.subtractingReportingOverflow(y), second = first.partialValue.subtractingReportingOverflow(borrow)
                words[out * width + j] = second.partialValue
                borrow = first.overflow || second.overflow ? 1 : 0
            }
            precondition(borrow == 0)
            try finish(out, count: lengths[large], sign: order > 0 ? negative[a] : bSign)
        } else {
            try zero(out); var carry: UInt64 = 0
            let count = max(lengths[a], lengths[b])
            for j in 0..<count {
                try tick()
                let x = j < lengths[a] ? words[a * width + j] : 0, y = j < lengths[b] ? words[b * width + j] : 0
                let first = x.addingReportingOverflow(y), second = first.partialValue.addingReportingOverflow(carry)
                words[out * width + j] = second.partialValue
                carry = first.overflow || second.overflow ? 1 : 0
            }
            if carry != 0 {
                guard count < width else { throw ExactRowAlgebra.Failure.bitLimit }
                words[out * width + count] = carry
            }
            try finish(out, count: count + (carry == 0 ? 0 : 1), sign: negative[a])
        }
    }
    func multiply(_ out: Int, _ a: Int, _ b: Int) throws {
        precondition(out != a && out != b)
        try zero(out)
        if isZero(a) || isZero(b) { return }
        guard lengths[a] <= width - lengths[b] + 1 else { throw ExactRowAlgebra.Failure.bitLimit }
        for i in 0..<lengths[a] {
            var carry: UInt64 = 0
            for j in 0..<lengths[b] {
                try tick(); let k = i + j
                let product = words[a * width + i].multipliedFullWidth(by: words[b * width + j])
                let first = words[out * width + k].addingReportingOverflow(product.low)
                let second = first.partialValue.addingReportingOverflow(carry)
                words[out * width + k] = second.partialValue
                let high = product.high.addingReportingOverflow(first.overflow ? 1 : 0)
                let next = high.partialValue.addingReportingOverflow(second.overflow ? 1 : 0)
                precondition(!high.overflow && !next.overflow)
                carry = next.partialValue
            }
            if carry != 0 {
                guard i + lengths[b] < width else { throw ExactRowAlgebra.Failure.bitLimit }
                words[out * width + i + lengths[b]] = carry
            }
        }
        try finish(out, count: min(width, lengths[a] + lengths[b]), sign: negative[a] != negative[b])
    }
    func export(_ a: Int, lease: any Sendable) throws -> ExactRowAlgebra.Scalar {
        try admitInitialization(lengths[a])
        try tick()
        var result = [UInt64](repeating: 0, count: lengths[a])
        for j in result.indices { try tick(); result[j] = words[a * width + j] }
        return .init(negative: negative[a], words: result, lease: lease)
    }
}
