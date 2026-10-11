import CoreSpiceCompile
import Testing

/// Independent small dense Gaussian solve for output-noise adjoint identities.
/// It does not call the production solver or stamper.
enum BSIM45ReferenceNetwork {
    static func solve(_ matrix: [[ComplexPair]], rhs: [ComplexPair]) throws -> [ComplexPair] {
        var a = matrix, b = rhs
        for column in b.indices {
            let pivot = try #require((column..<b.count).max { a[$0][column].magnitude < a[$1][column].magnitude })
            #expect(a[pivot][column].magnitude > 0)
            a.swapAt(pivot, column); b.swapAt(pivot, column)
            for row in (column + 1)..<b.count {
                let factor = a[row][column] / a[column][column]
                for k in column..<b.count { a[row][k] = a[row][k] - factor * a[column][k] }
                b[row] = b[row] - factor * b[column]
            }
        }
        var x = [ComplexPair](repeating: .zero, count: b.count)
        for row in b.indices.reversed() {
            var value = b[row]
            for k in (row + 1)..<b.count { value = value - a[row][k] * x[k] }
            x[row] = value / a[row][row]
        }
        return x
    }
}
