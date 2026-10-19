import CoreSpiceCompile

/// Exact structural permutations from Reference-LAPACK v3.12.1 DGGBAL JOB='P'.
/// These are equivalences of the pair, not numerical rank tests or beta thresholds.
extension QZIteration {
    mutating func isolate() throws {
        guard n > 1 else { return }
        var first = 1, last = n
        // Isolate rows with at most one nonzero in the union of A and B.
        while last > 1 {
            var selectedRow = 0, selectedColumn = 0
            search: for row in stride(from: last, through: 1, by: -1) {
                var nonzeroColumn = 0
                for column in 1...last {
                    if (column - 1) % 32 == 0 {
                        try control?.checkpoint(workUnits: min(32, last - column + 1) * 2)
                    }
                    if h[row, column] != 0 || t[row, column] != 0 {
                        if nonzeroColumn != 0 { continue search }
                        nonzeroColumn = column
                    }
                }
                selectedRow = row
                selectedColumn = nonzeroColumn == 0 ? last : nonzeroColumn
                break
            }
            guard selectedRow != 0 else { break }
            try interchange(row: selectedRow, column: selectedColumn, target: last)
            last -= 1
        }
        if last > 1 {
            // Isolate columns at the leading end; the remaining active square stays generic.
            while first < last {
                var selectedRow = 0, selectedColumn = 0
                search: for column in first...last {
                    var nonzeroRow = 0
                    for row in first...last {
                        if (row - first) % 32 == 0 {
                            try control?.checkpoint(workUnits: min(32, last - row + 1) * 2)
                        }
                        if h[row, column] != 0 || t[row, column] != 0 {
                            if nonzeroRow != 0 { continue search }
                            nonzeroRow = row
                        }
                    }
                    selectedRow = nonzeroRow == 0 ? last : nonzeroRow
                    selectedColumn = column
                    break
                }
                guard selectedColumn != 0 else { break }
                try interchange(row: selectedRow, column: selectedColumn, target: first)
                first += 1
            }
        }
        lower = first; upper = last
    }

    /// Inspected before QR, so exact triangularity is a source-structural fact.
    func hasNonsingularTriangularB() throws -> Bool {
        var upperTriangular = true, lowerTriangular = true
        for row in 1...n {
            try control?.checkpoint(workUnits: 1)
            if t[row, row] == 0 { return false }
            for column in 1...n {
                if (column - 1) % 32 == 0 {
                    try control?.checkpoint(workUnits: min(32, n - column + 1) * 2)
                }
                if row > column && t[row, column] != 0 { upperTriangular = false }
                if row < column && t[row, column] != 0 { lowerTriangular = false }
            }
        }
        return upperTriangular || lowerTriangular
    }

    private mutating func interchange(row: Int, column: Int, target: Int) throws {
        if row != target {
            for j in 1...n {
                if (j - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - j + 1) * 3) }
                let a = h[row, j], b = t[row, j], left = q[j, row]
                h[row, j] = h[target, j]; h[target, j] = a
                t[row, j] = t[target, j]; t[target, j] = b
                q[j, row] = q[j, target]; q[j, target] = left
            }
        }
        if column != target {
            for i in 1...n {
                if (i - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - i + 1) * 3) }
                let a = h[i, column], b = t[i, column], right = z[i, column]
                h[i, column] = h[i, target]; h[i, target] = a
                t[i, column] = t[i, target]; t[i, target] = b
                z[i, column] = z[i, target]; z[i, target] = right
            }
        }
    }
}
