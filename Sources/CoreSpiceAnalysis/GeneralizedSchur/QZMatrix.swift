import CoreSpiceCompile

/// One-based coordinates follow the fixed reference algorithm. Storage is column-major.
struct QZMatrix: Sendable {
    let n: Int
    var values: [Double]

    init(n: Int, values: [Double]) { self.n = n; self.values = values }

    subscript(_ row: Int, _ column: Int) -> Double {
        get { values[(column - 1) * n + row - 1] }
        set { values[(column - 1) * n + row - 1] = newValue }
    }

    mutating func rotateRows(_ x: Int, _ y: Int, from: Int, through: Int,
                             c: Double, s: Double,
                             control: (any LinearSolverExecutionControlling)?) throws {
        guard from <= through else { return }
        var column = from
        while column <= through {
            let end = min(through, column + 31)
            try control?.checkpoint(workUnits: (end - column + 1) * 6)
            while column <= end {
                let first = self[x, column], second = self[y, column]
                self[x, column] = c * first + s * second
                self[y, column] = c * second - s * first
                column += 1
            }
        }
    }

    mutating func rotateColumns(_ x: Int, _ y: Int, from: Int, through: Int,
                                c: Double, s: Double,
                                control: (any LinearSolverExecutionControlling)?) throws {
        guard from <= through else { return }
        var row = from
        while row <= through {
            let end = min(through, row + 31)
            try control?.checkpoint(workUnits: (end - row + 1) * 6)
            while row <= end {
                let first = self[row, x], second = self[row, y]
                self[row, x] = c * first + s * second
                self[row, y] = c * second - s * first
                row += 1
            }
        }
    }

    mutating func reflectRows(_ first: Int, from: Int, through: Int,
                              tau: Double, v2: Double, v3: Double,
                              control: (any LinearSolverExecutionControlling)?) throws {
        guard from <= through else { return }
        var column = from
        while column <= through {
            let end = min(through, column + 31)
            try control?.checkpoint(workUnits: (end - column + 1) * 14)
            while column <= end {
                let term = self[first, column] + v2 * self[first + 1, column] + v3 * self[first + 2, column]
                self[first, column] -= term * tau
                self[first + 1, column] -= term * (tau * v2)
                self[first + 2, column] -= term * (tau * v3)
                column += 1
            }
        }
    }

    mutating func reflectColumns(_ first: Int, from: Int, through: Int,
                                 tau: Double, v2: Double, v3: Double,
                                 control: (any LinearSolverExecutionControlling)?) throws {
        guard from <= through else { return }
        var row = from
        while row <= through {
            let end = min(through, row + 31)
            try control?.checkpoint(workUnits: (end - row + 1) * 14)
            while row <= end {
                let term = self[row, first] + v2 * self[row, first + 1] + v3 * self[row, first + 2]
                self[row, first] -= term * tau
                self[row, first + 1] -= term * (tau * v2)
                self[row, first + 2] -= term * (tau * v3)
                row += 1
            }
        }
    }
}
