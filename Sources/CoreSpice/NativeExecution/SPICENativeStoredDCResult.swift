import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR

/// Durable electrical DC state. Waveform/CSV values are binary64 display projections.
public struct SPICENativeStoredDCResult: Codable, Sendable, Hashable {
    public enum Failure: Error, Sendable { case invalidState, unsupportedOpticalState, pointOutOfBounds }
    public enum Representation: String, Codable, Sendable, Hashable { case binary64, compensated }
    public struct Row: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case nodeVoltage, branchCurrent }
        public let kind: Kind
        public let identifier: Int
        fileprivate var variable: MNAVariable {
            switch kind {
            case .nodeVoltage: .nodeVoltage(Node(id: identifier))
            case .branchCurrent: .branchCurrent(Branch(id: identifier))
            }
        }
    }
    public struct Point: Codable, Sendable, Hashable {
        public let representation: Representation
        public let highBits: [UInt64]
        public let lowBits: [UInt64]?
        public let iterations: Int
    }
    public let schemaVersion: Int
    public let analysis: String
    public let rows: [Row]
    public let parameterName: String?
    public let coordinateBits: [UInt64]?
    public let points: [Point]
    /// Numerical bits retain the native capacity owner; decoding creates independent values.
    private let retainedStorage: (any Sendable)?
    private enum CodingKeys: String, CodingKey { case schemaVersion, analysis, rows, parameterName, coordinateBits, points }

    public init(operatingPoint: DCResult) throws {
        try self.init(results: CollectionOfOne(operatingPoint), parameterName: nil, coordinates: nil)
    }
    public init(sweep: SweepResult<DCResult>) throws {
        try self.init(results: sweep.results, parameterName: sweep.parameterName, coordinates: sweep.values)
    }
    private init<Results: Collection>(results: Results, parameterName: String?, coordinates: [Double]?) throws where Results.Element == DCResult {
        guard let first = results.first else { throw Failure.invalidState }
        let owner = NativeExecutionStorage.nativeOwner(of: first.retainedStorage)
        let lease = try owner?.reserveMaterializationBytes(Self.storageCapacity(dimension: first.variables.count,
            pointCount: results.count, coordinateCount: coordinates?.count ?? 0))
        var ordered = [Row?](repeating: nil, count: first.variables.count)
        for (variable, index) in first.variableMap {
            guard ordered.indices.contains(index), ordered[index] == nil else { throw Failure.invalidState }
            switch variable {
            case .nodeVoltage(let node): ordered[index] = Row(kind: .nodeVoltage, identifier: node.id)
            case .branchCurrent(let branch): ordered[index] = Row(kind: .branchCurrent, identifier: branch.id)
            }
        }
        var rows: [Row] = []; rows.reserveCapacity(ordered.count)
        for row in ordered { guard let row else { throw Failure.invalidState }; rows.append(row) }
        var points: [Point] = []; points.reserveCapacity(results.count)
        for result in results {
            guard result.opticalState == nil else { throw Failure.unsupportedOpticalState }
            guard result.variableMap == first.variableMap else { throw Failure.invalidState }
            points.append(Point(representation: result.variableLowComponents == nil ? .binary64 : .compensated,
                highBits: result.variables.map(\.bitPattern), lowBits: result.variableLowComponents?.map(\.bitPattern),
                iterations: result.iterations))
        }
        schemaVersion = 1; analysis = parameterName == nil ? "op" : "dc"
        self.rows = rows; self.parameterName = parameterName; coordinateBits = coordinates?.map(\.bitPattern)
        self.points = points; retainedStorage = lease
        try validate()
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        analysis = try c.decode(String.self, forKey: .analysis)
        rows = try c.decode([Row].self, forKey: .rows)
        parameterName = try c.decodeIfPresent(String.self, forKey: .parameterName)
        coordinateBits = try c.decodeIfPresent([UInt64].self, forKey: .coordinateBits)
        points = try c.decode([Point].self, forKey: .points)
        retainedStorage = nil
        try validate()
    }
    private func validate() throws {
        guard schemaVersion == 1, !rows.isEmpty, !points.isEmpty,
              Set(rows.map(\.variable)).count == rows.count,
              rows.allSatisfy({ $0.identifier >= 0 && ($0.kind != .nodeVoltage || $0.identifier > 0) }) else { throw Failure.invalidState }
        switch analysis {
        case "op": guard points.count == 1, parameterName == nil, coordinateBits == nil else { throw Failure.invalidState }
        case "dc": guard let parameterName, !parameterName.isEmpty, let coordinateBits,
                         coordinateBits.count == points.count,
                         coordinateBits.allSatisfy({ Double(bitPattern: $0).isFinite }) else { throw Failure.invalidState }
        default: throw Failure.invalidState
        }
        for point in points {
            guard point.iterations >= 0, point.highBits.count == rows.count,
                  (point.representation == .compensated) == (point.lowBits != nil),
                  point.lowBits == nil || point.lowBits?.count == rows.count else { throw Failure.invalidState }
            for index in rows.indices {
                _ = try CompensatedValue(high: Double(bitPattern: point.highBits[index]),
                    low: point.lowBits.map { Double(bitPattern: $0[index]) } ?? 0)
            }
        }
    }
    /// Restores canonical pairs; no executable model storage or optical state is reconstructed.
    public func result(at index: Int) throws -> DCResult {
        guard points.indices.contains(index) else { throw Failure.pointOutOfBounds }
        let point = points[index]
        let owner = NativeExecutionStorage.nativeOwner(of: retainedStorage)
        let perRow = UInt64(2 * MemoryLayout<Double>.stride + 4 * (MemoryLayout<MNAVariable>.stride + MemoryLayout<Int>.stride) + 4 * MemoryLayout<Int>.stride)
        let lease = try owner?.reserveMaterializationBytes(NativeCircuitExecution.capacitySum(UInt64(MemoryLayout<DCResult>.stride),
            NativeCircuitExecution.capacityProduct(UInt64(rows.count), perRow)))
        var map: [MNAVariable: Int] = [:]; map.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() { map[row.variable] = index }
        let result = try DCResult(variables: point.highBits.map { Double(bitPattern: $0) },
            variableMap: map, iterations: point.iterations,
            variableLowComponents: point.lowBits?.map { Double(bitPattern: $0) })
        if let lease { return result.retainingStorage(lease) }
        return result
    }
    private static func storageCapacity(dimension: Int, pointCount: Int, coordinateCount: Int) throws -> UInt64 {
        // Ordered optional rows, final rows, validation map/Set, exact bits and point headers.
        let rowStride = UInt64(MemoryLayout<Row?>.stride + MemoryLayout<Row>.stride +
            5 * (MemoryLayout<MNAVariable>.stride + MemoryLayout<Int>.stride))
        let rowBytes = try NativeCircuitExecution.capacityProduct(UInt64(dimension), rowStride)
        let bits = try NativeCircuitExecution.capacityProduct(
            NativeCircuitExecution.capacityProduct(UInt64(dimension), UInt64(pointCount)), 2 * UInt64(MemoryLayout<UInt64>.stride))
        let headers = try NativeCircuitExecution.capacityProduct(UInt64(pointCount), UInt64(MemoryLayout<Point>.stride))
        return try NativeCircuitExecution.capacitySum(rowBytes, NativeCircuitExecution.capacitySum(bits,
            NativeCircuitExecution.capacitySum(headers, NativeCircuitExecution.capacityProduct(UInt64(coordinateCount), UInt64(MemoryLayout<UInt64>.stride)))))
    }
    /// CLI encoding admits the additional DC payload's encode/string/reload coexistence.
    package func withSerialization<Result>(_ body: () throws -> Result) throws -> Result {
        guard let storage = NativeExecutionStorage.nativeOwner(of: retainedStorage) else { return try body() }
        var bytes = UInt64(512)
        for point in points {
            let count = try NativeCircuitExecution.capacitySum(UInt64(point.highBits.count), UInt64(point.lowBits?.count ?? 0))
            bytes = try NativeCircuitExecution.capacitySum(bytes,
                NativeCircuitExecution.capacitySum(256, NativeCircuitExecution.capacityProduct(count, 32)))
        }
        bytes = try NativeCircuitExecution.capacitySum(bytes, NativeCircuitExecution.capacityProduct(UInt64(rows.count), 256))
        bytes = try NativeCircuitExecution.capacitySum(bytes, NativeCircuitExecution.capacityProduct(UInt64(coordinateBits?.count ?? 0), 32))
        bytes = try NativeCircuitExecution.capacitySum(bytes, NativeCircuitExecution.capacityProduct(UInt64(parameterName?.utf8.count ?? 0), 6))
        let reservation = try storage.reserveTemporaryBytes(NativeCircuitExecution.capacityProduct(bytes, 4))
        defer { withExtendedLifetime(reservation) {} }
        return try body()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.analysis == rhs.analysis && lhs.rows == rhs.rows &&
        lhs.parameterName == rhs.parameterName && lhs.coordinateBits == rhs.coordinateBits && lhs.points == rhs.points
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion); hasher.combine(analysis); hasher.combine(rows)
        hasher.combine(parameterName); hasher.combine(coordinateBits); hasher.combine(points)
    }
}
