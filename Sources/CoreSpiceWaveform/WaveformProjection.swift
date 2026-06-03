/// A prevalidated point and variable projection for waveform views.
///
/// The projection normalizes identity index lists to `nil` and caches whether
/// the visible variables form a contiguous slice. Reusing a projection avoids
/// repeating bounds checks and slice discovery when constructing many views over
/// the same waveform shape.
public struct WaveformProjection: Sendable {
    public struct RegularPointPattern: Sendable {
        public let start: Int
        public let stride: Int

        public init(start: Int, stride: Int) {
            self.start = start
            self.stride = stride
        }

        public func basePointIndex(for point: Int) -> Int {
            start + (point * stride)
        }
    }

    public let basePointCount: Int
    public let baseVariableCount: Int
    public let pointIndices: [Int]?
    public let variableIndices: [Int]?
    public let pointCount: Int
    public let variableCount: Int
    public let regularPointPattern: RegularPointPattern?
    public let contiguousVariableSlice: Range<Int>?

    public init(
        basePointCount: Int,
        baseVariableCount: Int,
        pointIndices: [Int]? = nil,
        variableIndices: [Int]? = nil
    ) {
        precondition(basePointCount >= 0, "basePointCount must not be negative")
        precondition(baseVariableCount >= 0, "baseVariableCount must not be negative")
        if let pointIndices {
            precondition(pointIndices.allSatisfy { $0 >= 0 && $0 < basePointCount })
        }
        if let variableIndices {
            precondition(variableIndices.allSatisfy { $0 >= 0 && $0 < baseVariableCount })
        }

        let normalizedPointIndices = Self.identityOrNil(pointIndices, count: basePointCount)
        let normalizedVariableIndices = Self.identityOrNil(variableIndices, count: baseVariableCount)

        self.basePointCount = basePointCount
        self.baseVariableCount = baseVariableCount
        self.pointIndices = normalizedPointIndices
        self.variableIndices = normalizedVariableIndices
        self.pointCount = normalizedPointIndices?.count ?? basePointCount
        self.variableCount = normalizedVariableIndices?.count ?? baseVariableCount
        self.regularPointPattern = Self.regularPointPattern(normalizedPointIndices)
        self.contiguousVariableSlice = Self.contiguousSlice(
            normalizedVariableIndices,
            baseVariableCount: baseVariableCount
        )
    }

    public func basePointIndex(for point: Int) -> Int? {
        guard point >= 0, point < pointCount else { return nil }
        if let regularPointPattern {
            return regularPointPattern.basePointIndex(for: point)
        }
        guard let pointIndices else { return point }
        return pointIndices[point]
    }

    public func baseVariableIndex(for variable: Int) -> Int? {
        guard variable >= 0, variable < variableCount else { return nil }
        guard let variableIndices else { return variable }
        return variableIndices[variable]
    }

    private static func contiguousSlice(_ indices: [Int]?, baseVariableCount: Int) -> Range<Int>? {
        guard let indices else {
            return 0..<baseVariableCount
        }
        guard let first = indices.first else {
            return 0..<0
        }
        for offset in indices.indices {
            if indices[offset] != first + offset {
                return nil
            }
        }
        return first..<(first + indices.count)
    }

    private static func regularPointPattern(_ indices: [Int]?) -> RegularPointPattern? {
        guard let indices else {
            return RegularPointPattern(start: 0, stride: 1)
        }
        guard let first = indices.first else {
            return RegularPointPattern(start: 0, stride: 1)
        }
        guard indices.count > 1 else {
            return RegularPointPattern(start: first, stride: 1)
        }

        let stride = indices[1] - first
        for offset in indices.indices.dropFirst(2) {
            if indices[offset] != first + (offset * stride) {
                return nil
            }
        }
        return RegularPointPattern(start: first, stride: stride)
    }

    private static func identityOrNil(_ indices: [Int]?, count: Int) -> [Int]? {
        guard let indices else { return nil }
        if indices.elementsEqual(0..<count) {
            return nil
        }
        return indices
    }
}
