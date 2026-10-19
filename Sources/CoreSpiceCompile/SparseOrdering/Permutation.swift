/// A permutation vector that maps between original and reordered indices.
public struct Permutation: Sendable, Equatable {

    /// Maps original index to reordered index: `reordered[forward[i]] = original[i]`
    public let forward: [Int]

    /// Maps reordered index to original index: `original[inverse[i]] = reordered[i]`
    public let inverse: [Int]

    private let storageLease: (any Sendable)?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.forward == rhs.forward && lhs.inverse == rhs.inverse
    }

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
        self.storageLease = nil
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
        self.storageLease = nil
        self.forward = forward
        self.inverse = inverse
    }

    init(forward: [Int], inverse: [Int], storageLease: (any Sendable)?) {
        self.forward = forward
        self.inverse = inverse
        self.storageLease = storageLease
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
