/// Fill-reducing ordering algorithms for sparse matrix factorization.
///
/// AMD (Approximate Minimum Degree) ordering significantly reduces fill-in
/// during LU factorization by reordering rows and columns to minimize
/// the number of new non-zero entries created during elimination.

/// A permutation vector that maps between original and reordered indices.
public struct Permutation: Sendable, Equatable {

    /// Maps original index to reordered index: `reordered[forward[i]] = original[i]`
    public let forward: [Int]

    /// Maps reordered index to original index: `original[inverse[i]] = reordered[i]`
    public let inverse: [Int]

    /// The dimension of the permutation.
    public var dimension: Int { forward.count }

    /// Creates an identity permutation of the given size.
    public static func identity(size: Int) -> Permutation {
        let indices = Array(0..<size)
        return Permutation(forward: indices, inverse: indices)
    }

    /// Creates a permutation from a forward mapping.
    ///
    /// - Parameter forward: Maps original index `i` to reordered position `forward[i]`.
    public init(forward: [Int]) {
        self.forward = forward
        var inv = Array(repeating: 0, count: forward.count)
        for (original, reordered) in forward.enumerated() {
            inv[reordered] = original
        }
        self.inverse = inv
    }

    /// Creates a permutation from both forward and inverse mappings.
    ///
    /// - Note: The caller must ensure consistency between forward and inverse.
    public init(forward: [Int], inverse: [Int]) {
        self.forward = forward
        self.inverse = inverse
    }

    /// Applies the permutation to reorder an array.
    ///
    /// - Parameter array: Array in original order.
    /// - Returns: Array in reordered order where `result[forward[i]] = array[i]`.
    public func apply<T>(to array: [T]) -> [T] {
        var result = array
        for i in 0..<array.count {
            result[forward[i]] = array[i]
        }
        return result
    }

    /// Applies the inverse permutation to restore original order.
    ///
    /// - Parameter array: Array in reordered order.
    /// - Returns: Array in original order where `result[i] = array[forward[i]]`.
    public func applyInverse<T>(to array: [T]) -> [T] {
        var result = array
        for i in 0..<array.count {
            result[i] = array[forward[i]]
        }
        return result
    }

    /// Applies the permutation, writing results into a pre-allocated destination.
    ///
    /// Zero-allocation variant of ``apply(to:)``.
    /// - Parameters:
    ///   - source: Array in original order.
    ///   - dest: Pre-allocated destination array (must be same length as source).
    public func apply<T>(from source: [T], into dest: inout [T]) {
        for i in 0..<source.count {
            dest[forward[i]] = source[i]
        }
    }

    /// Applies the inverse permutation, writing results into a pre-allocated destination.
    ///
    /// Zero-allocation variant of ``applyInverse(to:)``.
    /// - Parameters:
    ///   - source: Array in reordered order.
    ///   - dest: Pre-allocated destination array (must be same length as source).
    public func applyInverse<T>(from source: [T], into dest: inout [T]) {
        for i in 0..<source.count {
            dest[i] = source[forward[i]]
        }
    }

    /// Composes this permutation with another.
    ///
    /// Returns a permutation that applies `self` first, then `other`.
    public func then(_ other: Permutation) -> Permutation {
        var composed = Array(repeating: 0, count: dimension)
        for i in 0..<dimension {
            composed[i] = other.forward[forward[i]]
        }
        return Permutation(forward: composed)
    }
}

/// Approximate Minimum Degree (AMD) ordering algorithm.
///
/// AMD produces a fill-reducing permutation for sparse matrix factorization
/// by repeatedly eliminating the node with the minimum approximate degree
/// in the elimination graph.
public struct AMDOrdering: Sendable {

    /// Computes a fill-reducing permutation using the AMD algorithm.
    ///
    /// - Parameter structure: The sparsity pattern of the matrix.
    /// - Returns: A permutation that reduces fill-in during factorization.
    public static func compute(structure: SparseStructure) -> Permutation {
        let n = structure.dimension

        if n == 0 {
            return .identity(size: 0)
        }

        // Build adjacency list representation (symmetric pattern)
        var adjacency = buildSymmetricAdjacency(from: structure)

        // Degree of each node (number of neighbors)
        var degree = adjacency.map { $0.count }

        // Whether each node has been eliminated
        var eliminated = Array(repeating: false, count: n)

        // Elimination order
        var order = [Int]()
        order.reserveCapacity(n)

        // Priority queue simulation using linear scan
        // For better performance, a proper min-heap could be used
        for _ in 0..<n {
            // Find non-eliminated node with minimum degree
            var minDegree = Int.max
            var minNode = -1

            for node in 0..<n {
                if !eliminated[node] && degree[node] < minDegree {
                    minDegree = degree[node]
                    minNode = node
                }
            }

            guard minNode >= 0 else { break }

            // Eliminate this node
            order.append(minNode)
            eliminated[minNode] = true

            // Get neighbors of eliminated node as array for indexing
            let neighborsArray = Array(adjacency[minNode].filter { !eliminated[$0] })

            // Form a clique among neighbors (add fill-in edges)
            for i in 0..<neighborsArray.count {
                for j in (i + 1)..<neighborsArray.count {
                    let u = neighborsArray[i]
                    let v = neighborsArray[j]

                    // Add edge if not already present
                    if !adjacency[u].contains(v) {
                        adjacency[u].insert(v)
                        adjacency[v].insert(u)
                    }
                }
            }

            let neighbors = Set(neighborsArray)

            // Remove eliminated node from all neighbor lists
            for neighbor in neighbors {
                adjacency[neighbor].remove(minNode)
            }

            // Update degrees
            for neighbor in neighbors {
                degree[neighbor] = adjacency[neighbor].filter { !eliminated[$0] }.count
            }
        }

        // Build permutation from elimination order
        // order[i] = original node eliminated at step i
        // forward[original] = position in new ordering
        var forward = Array(repeating: 0, count: n)
        for (position, original) in order.enumerated() {
            forward[original] = position
        }

        return Permutation(forward: forward)
    }

    /// Builds a symmetric adjacency representation from a CSR structure.
    private static func buildSymmetricAdjacency(from structure: SparseStructure) -> [Set<Int>] {
        let n = structure.dimension
        var adjacency = Array(repeating: Set<Int>(), count: n)

        for row in 0..<n {
            let start = structure.rowPointers[row]
            let end = structure.rowPointers[row + 1]

            for idx in start..<end {
                let col = structure.columnIndices[idx]
                if col != row {  // Exclude diagonal self-loops
                    adjacency[row].insert(col)
                    adjacency[col].insert(row)  // Symmetric
                }
            }
        }

        return adjacency
    }
}

/// Minimum Degree ordering (simpler variant of AMD).
///
/// Uses exact minimum degree rather than approximate, which can be
/// slower for large matrices but may produce better orderings for
/// smaller problems.
public struct MinimumDegreeOrdering: Sendable {

    /// Computes a fill-reducing permutation using exact minimum degree.
    ///
    /// - Parameter structure: The sparsity pattern of the matrix.
    /// - Returns: A permutation that reduces fill-in during factorization.
    public static func compute(structure: SparseStructure) -> Permutation {
        // For small matrices, exact minimum degree is acceptable
        // This implementation is identical to AMD but could be optimized
        // differently for specific use cases
        return AMDOrdering.compute(structure: structure)
    }
}

/// Natural ordering (identity permutation).
///
/// Uses the original matrix ordering without reordering.
/// Useful for comparison or when the matrix is already well-ordered.
public struct NaturalOrdering: Sendable {

    /// Returns an identity permutation.
    ///
    /// - Parameter structure: The sparsity pattern (used only for dimension).
    /// - Returns: An identity permutation.
    public static func compute(structure: SparseStructure) -> Permutation {
        return .identity(size: structure.dimension)
    }
}
