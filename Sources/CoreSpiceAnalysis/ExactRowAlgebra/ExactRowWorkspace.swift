/// Operation-local integer rows and their original-row transforms share one admitted pool.
final class ExactRowWorkspace {
    typealias Scalar = ExactRowAlgebra.Scalar
    typealias Rows = ExactRowAlgebra.Rows
    typealias Failure = ExactRowAlgebra.Failure
    enum LocatedCertificate { case member; case nonmember }
    let algebra: ExactRowAlgebra
    let input: Rows
    let query: [Scalar]?
    let pool: ExactLimbPool
    let size: Int
    let n: Int
    let t: Int
    let q: Int
    let c: Int
    let z: Int
    let h: Int
    let scratch: Int
    private var order: [Int]
    private var pivots: [Int]
    private var powers: [UInt64]
    private var rank = 0

    init(algebra: ExactRowAlgebra, rows: Rows, query: [Scalar]?, completion: Bool) throws {
        self.algebra = algebra; input = rows; self.query = query; n = rows.columnCount
        try algebra.control.checkpoint(workUnits: 0)
        guard rows.rowCount >= 0, rows.rowCount <= algebra.limits.maximumRows,
              n > 0, n <= algebra.limits.maximumColumns,
              !completion || rows.rowCount <= n, query == nil || query!.count == n else { throw Failure.invalidInput }
        let cells = try TransientExecutionBudget.multiply(rows.rowCount, n, "exact input cells")
        guard cells == rows.values.count else { throw Failure.invalidInput }
        for value in rows.values { try Self.validate(value, algebra: algebra) }
        if let query { for value in query { try Self.validate(value, algebra: algebra) } }
        size = completion ? n : rows.rowCount
        t = try TransientExecutionBudget.multiply(size, n, "exact working rows")
        q = try TransientExecutionBudget.add(t, TransientExecutionBudget.multiply(size, size, "exact transforms"), "exact query offset")
        c = try TransientExecutionBudget.add(q, n, "exact coefficient offset")
        z = try TransientExecutionBudget.add(c, size, "exact separator offset")
        h = try TransientExecutionBudget.add(z, n, "exact inverse offset")
        let inverse = completion ? try TransientExecutionBudget.multiply(n, n, "exact inverse") : 0
        scratch = try TransientExecutionBudget.add(h, inverse, "exact scratch offset")
        let slots = try TransientExecutionBudget.add(scratch, 16, "exact scalar scratch")
        let indexCount = try TransientExecutionBudget.add(size,
            TransientExecutionBudget.add(n, TransientExecutionBudget.add(rows.rowCount, n, "exact row powers and selectors"), "exact pivots"), "exact indices")
        let metadata = try TransientExecutionBudget.multiply(indexCount, 8, "exact index payload")
        pool = try ExactLimbPool(slots: slots, metadataBytes: metadata, limits: algebra.limits, control: algebra.control)
        let initializedIndices = try TransientExecutionBudget.add(size,
            TransientExecutionBudget.add(n, rows.rowCount, "exact pivot and power initialization"), "exact index initialization")
        try pool.admitInitialization(initializedIndices)
        order = [Int](repeating: 0, count: size); pivots = [Int](repeating: -1, count: n)
        powers = [UInt64](repeating: 0, count: rows.rowCount)
        for row in 0..<rows.rowCount {
            for column in 0..<n { try pool.tick(); powers[row] = max(powers[row], rows.values[row * n + column].denominatorPower) }
        }
        try reset()
    }

    private static func validate(_ value: Scalar, algebra: ExactRowAlgebra, integer: Bool = false) throws {
        try algebra.control.checkpoint(workUnits: 3)
        if integer && value.denominatorPower != 0 { throw Failure.invalidInput }
        guard value.denominatorPower < UInt64(algebra.limits.maximumIntegerBits) else { throw Failure.bitLimit }
        guard let high = value.words.last else {
            guard !value.negative && value.denominatorPower == 0 else { throw Failure.invalidInput }
            return
        }
        guard high != 0, value.denominatorPower == 0 || value.words[0] & 1 == 1 else { throw Failure.invalidInput }
        let bits = try TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(value.words.count - 1, 64, "exact numerator bits"),
            64 - high.leadingZeroBitCount, "exact numerator bits")
        guard bits <= algebra.limits.maximumIntegerBits else { throw Failure.bitLimit }
    }
    private var scale: Int { scratch }
    private var pivot: Int { scratch + 1 }
    private var entry: Int { scratch + 2 }
    private var first: Int { scratch + 3 }
    private var second: Int { scratch + 4 }
    private var sum: Int { scratch + 6 }
    private var loaded: Int { scratch + 7 }
    private var product: Int { scratch + 8 }

    private func reset() throws {
        for slot in 0..<q { try pool.tick(); try pool.zero(slot) }
        for row in 0..<size { try pool.tick(); order[row] = row; try pool.one(t + row * size + row) }
        rank = 0
        for column in 0..<n { try pool.tick(); pivots[column] = -1 }
        for row in 0..<input.rowCount {
            for column in 0..<n {
                try pool.load(row * n + column, input.values[row * n + column], clearingPower: powers[row])
            }
        }
    }
    private func combine(_ out: Int, _ x: Int, _ y: Int, subtract: Bool = true) throws {
        try pool.multiply(first, pivot, x)
        try pool.multiply(second, entry, y)
        try pool.add(out, first, second, subtract: subtract)
    }
    private func eliminate(row: Int, using pivotRow: Int, column: Int) throws {
        try pool.copy(pivot, pivotRow * n + column)
        try pool.copy(entry, row * n + column)
        for j in 0..<n { try pool.tick(); try combine(row * n + j, row * n + j, pivotRow * n + j) }
        for j in 0..<size { try pool.tick(); try combine(t + row * size + j, t + row * size + j, t + pivotRow * size + j) }
    }
    private func echelon(rowCount: Int) throws {
        rank = 0
        for column in 0..<n {
            if rank == rowCount { break }
            var selected = rank
            while selected < rowCount {
                try pool.tick(); if !pool.isZero(order[selected] * n + column) { break }; selected += 1
            }
            if selected == rowCount { continue }
            order.swapAt(rank, selected); pivots[rank] = column
            let pivotRow = order[rank]
            for position in (rank + 1)..<rowCount {
                try pool.tick(); let row = order[position]
                if !pool.isZero(row * n + column) { try eliminate(row: row, using: pivotRow, column: column) }
            }
            rank += 1
        }
    }
    func membership() throws -> LocatedCertificate {
        guard let query else { throw Failure.invalidInput }
        try echelon(rowCount: input.rowCount)
        var power: UInt64 = 0
        for value in query { try pool.tick(); power = max(power, value.denominatorPower) }
        for column in 0..<n { try pool.load(q + column, query[column], clearingPower: power) }
        try pool.one(scale)
        for position in 0..<rank {
            let column = pivots[position], row = order[position]
            try pool.tick(); if pool.isZero(q + column) { continue }
            try pool.copy(pivot, row * n + column); try pool.copy(entry, q + column)
            for j in 0..<n { try combine(q + j, q + j, row * n + j) }
            for j in 0..<input.rowCount { try combine(c + j, c + j, t + row * size + j, subtract: false) }
            try pool.multiply(first, scale, pivot); try pool.copy(scale, first)
        }
        var nonzero: Int?
        for column in 0..<n { try pool.tick(); if !pool.isZero(q + column) { nonzero = column; break } }
        if let nonzero {
            try pool.one(z + nonzero)
            for position in (0..<rank).reversed() {
                let row = order[position], column = pivots[position]
                try pool.zero(sum)
                for j in 0..<n {
                    try pool.multiply(first, row * n + j, z + j)
                    try pool.add(second, sum, first); try pool.copy(sum, second)
                }
                try pool.copy(pivot, row * n + column)
                for j in 0..<n { try pool.multiply(first, z + j, pivot); try pool.copy(z + j, first) }
                try pool.add(first, z + column, sum, subtract: true); try pool.copy(z + column, first)
            }
            return .nonmember
        }
        for row in 0..<input.rowCount { try pool.shift(first, c + row, power: powers[row]); try pool.copy(c + row, first) }
        try pool.shift(first, scale, power: power); try pool.copy(scale, first)
        if pool.isNegative(scale) {
            pool.negate(scale)
            for row in 0..<input.rowCount { try pool.tick(); pool.negate(c + row) }
        }
        return .member
    }
    func export(_ certificate: LocatedCertificate, lease: any Sendable) throws -> ExactRowAlgebra.MembershipCertificate {
        switch certificate {
        case .member:
            try pool.admitInitialization(input.rowCount)
            var values = [Scalar](repeating: .zero, count: input.rowCount)
            for row in values.indices { values[row] = try pool.export(c + row, lease: lease) }
            return .member(scale: try pool.export(scale, lease: lease), coefficients: values)
        case .nonmember:
            try pool.admitInitialization(n)
            var values = [Scalar](repeating: .zero, count: n)
            for column in values.indices { values[column] = try pool.export(z + column, lease: lease) }
            return .nonmember(separator: values)
        }
    }
    func complete() throws -> [Int] {
        try echelon(rowCount: input.rowCount)
        guard rank == input.rowCount else { throw Failure.dependentBasis }
        try pool.admitInitialization(n - rank)
        var selectors = [Int](repeating: 0, count: n - rank), next = 0
        for column in 0..<n {
            try pool.tick()
            var selected = false
            for position in 0..<rank { try pool.tick(); if pivots[position] == column { selected = true; break } }
            if !selected { selectors[next] = column; next += 1 }
        }
        try reset()
        for index in selectors.indices { try pool.one((input.rowCount + index) * n + selectors[index]) }
        try echelon(rowCount: n)
        guard rank == n else { throw Failure.inconsistentCertificate }
        for position in (0..<n).reversed() {
            for earlier in 0..<position {
                try pool.tick()
                let row = order[earlier], pivotRow = order[position], column = pivots[position]
                if !pool.isZero(row * n + column) { try eliminate(row: row, using: pivotRow, column: column) }
            }
        }
        try pool.one(scale)
        for i in 0..<n { try pool.multiply(first, scale, order[i] * n + i); try pool.copy(scale, first) }
        for row in 0..<n {
            try pool.one(product)
            for other in 0..<n where other != row {
                try pool.tick(); try pool.multiply(first, product, order[other] * n + other); try pool.copy(product, first)
            }
            for column in 0..<n {
                try pool.multiply(first, product, t + order[row] * size + column)
                try pool.shift(h + row * n + column, first, power: column < input.rowCount ? powers[column] : 0)
            }
        }
        if pool.isNegative(scale) {
            pool.negate(scale)
            for cell in 0..<(n * n) { try pool.tick(); pool.negate(h + cell) }
        }
        return selectors
    }
    func exportCompletion(selectors: [Int], lease: any Sendable) throws -> ExactRowAlgebra.CompletionCertificate {
        let cells = try TransientExecutionBudget.multiply(n, n, "exact exported inverse initialization")
        try pool.admitInitialization(cells)
        var values = [Scalar](repeating: .zero, count: cells)
        for cell in values.indices { values[cell] = try pool.export(h + cell, lease: lease) }
        try pool.admitInitialization(selectors.count)
        var copied = [Int](repeating: 0, count: selectors.count)
        for i in copied.indices { try pool.tick(); copied[i] = selectors[i] }
        return .init(selectors: copied, inverseNumerators: values, scale: try pool.export(scale, lease: lease), lease: lease)
    }

    private func integer(_ slot: Int, _ value: Scalar) throws {
        try Self.validate(value, algebra: algebra, integer: true)
        try pool.load(slot, value, clearingPower: 0)
    }
    private func commonPower(_ query: [Scalar] = []) throws -> UInt64 {
        var power: UInt64 = 0
        for value in input.values { try pool.tick(); power = max(power, value.denominatorPower) }
        for value in query { try pool.tick(); power = max(power, value.denominatorPower) }
        return power
    }
    func verify(rows: Rows, query: [Scalar], certificate: ExactRowAlgebra.MembershipCertificate) throws {
        let power = try commonPower(query)
        switch certificate {
        case .member(let d, let coefficients):
            guard coefficients.count == rows.rowCount else { throw Failure.inconsistentCertificate }
            try integer(scale, d)
            guard !pool.isZero(scale) else { throw Failure.inconsistentCertificate }
            for row in coefficients.indices { try integer(c + row, coefficients[row]) }
            for column in 0..<n {
                try pool.load(loaded, query[column], clearingPower: power)
                try pool.multiply(product, scale, loaded); try pool.zero(sum)
                for row in 0..<rows.rowCount {
                    try pool.load(loaded, rows.values[row * n + column], clearingPower: power)
                    try pool.multiply(first, c + row, loaded)
                    try pool.add(second, sum, first); try pool.copy(sum, second)
                }
                guard try pool.equal(sum, product) else { throw Failure.inconsistentCertificate }
            }
        case .nonmember(let separator):
            guard separator.count == n else { throw Failure.inconsistentCertificate }
            var nonzero = false
            for column in 0..<n { try integer(z + column, separator[column]); nonzero = nonzero || !pool.isZero(z + column) }
            guard nonzero else { throw Failure.inconsistentCertificate }
            for row in 0...rows.rowCount {
                try pool.zero(sum)
                for column in 0..<n {
                    let value = row == rows.rowCount ? query[column] : rows.values[row * n + column]
                    try pool.load(loaded, value, clearingPower: power)
                    try pool.multiply(first, loaded, z + column)
                    try pool.add(second, sum, first); try pool.copy(sum, second)
                }
                guard pool.isZero(sum) == (row < rows.rowCount) else { throw Failure.inconsistentCertificate }
            }
        }
    }
    func verify(basis: Rows, certificate: ExactRowAlgebra.CompletionCertificate) throws {
        guard certificate.selectors.count == n - basis.rowCount,
              certificate.inverseNumerators.count == n * n else { throw Failure.inconsistentCertificate }
        var previous = -1
        for selected in certificate.selectors {
            try pool.tick(); guard selected > previous, selected < n else { throw Failure.inconsistentCertificate }; previous = selected
        }
        try integer(scale, certificate.scale)
        guard !pool.isZero(scale), !pool.isNegative(scale) else { throw Failure.inconsistentCertificate }
        for cell in certificate.inverseNumerators.indices { try integer(h + cell, certificate.inverseNumerators[cell]) }
        let power = try commonPower()
        for row in 0..<n { for column in 0..<n {
            try pool.zero(sum)
            for term in 0..<n {
                if term < basis.rowCount {
                    try pool.load(loaded, basis.values[term * n + column], clearingPower: power)
                } else if certificate.selectors[term - basis.rowCount] == column {
                    try pool.one(first); try pool.shift(loaded, first, power: power)
                } else { try pool.zero(loaded) }
                try pool.multiply(first, h + row * n + term, loaded)
                try pool.add(second, sum, first); try pool.copy(sum, second)
            }
            if row == column { try pool.shift(first, scale, power: power) } else { try pool.zero(first) }
            guard try pool.equal(sum, first) else { throw Failure.inconsistentCertificate }
        }}
    }
}
