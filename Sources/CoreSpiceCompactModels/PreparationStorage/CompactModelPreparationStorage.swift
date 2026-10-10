import CoreSpiceMOSContracts

/// Counts preparation payload capacities, excluding existing input backing and allocator metadata.
struct CompactModelPreparationStorage {
    let limits: MOSPreparationLimits
    let control: (any MOSPreparationControlling)?
    // The two-scope iteration retains a fixed array of dictionary views during setup.
    private var scopeBytes = UInt64(2 * MemoryLayout<(Bool, [String: Double])>.stride)
    private(set) var temporaryBytes: UInt64 = 0
    private(set) var workUnits: UInt64 = 0

    init(limits: MOSPreparationLimits, control: (any MOSPreparationControlling)?) {
        self.limits = limits
        self.control = control
    }

    mutating func admitScopeCapacity(_ capacity: Int) throws {
        scopeBytes = try Self.bytes(capacity, of: (Bool, [String: Double]).self)
        try check(0)
    }

    mutating func check(_ bytes: UInt64) throws {
        try control?.checkCancellation()
        let payload = try Self.add(bytes, scopeBytes)
        guard payload <= limits.maximumTemporaryBytes else { throw MOSPreparationFailure.capacityExceeded }
        temporaryBytes = max(temporaryBytes, payload)
    }

    mutating func charge() throws {
        try control?.checkCancellation()
        let (next, overflow) = workUnits.addingReportingOverflow(1)
        guard !overflow else { throw MOSPreparationFailure.arithmeticOverflow }
        guard next <= limits.maximumWorkUnits else { throw MOSPreparationFailure.workLimitExceeded }
        try control?.chargeWork(units: 1)
        workUnits = next
    }

    static func bytes<T>(_ capacity: Int, of: T.Type) throws -> UInt64 {
        guard let count = UInt64(exactly: capacity) else { throw MOSPreparationFailure.arithmeticOverflow }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: UInt64(MemoryLayout<T>.stride))
        guard !overflow else { throw MOSPreparationFailure.arithmeticOverflow }
        return bytes
    }

    static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MOSPreparationFailure.arithmeticOverflow }
        return sum
    }

    /// Existing standalone API has finite policy derived from original ABI capacities.
    static func standaloneLimits(parameterCapacity: Int, diagnosticStride: Int, ownerBytes: UInt64) throws -> MOSPreparationLimits {
        let diagnosticEnvelope = try bytes(32768, of: Substring.self)
            + UInt64(32768 * diagnosticStride) + 2 * 32768
        let parameterEnvelope = try bytes(parameterCapacity, of: (String, Double).self)
            + bytes(parameterCapacity, of: String.self) + UInt64(parameterCapacity * 64)
        let capacity = try add(ownerBytes, add(diagnosticEnvelope, parameterEnvelope))
        return try MOSPreparationLimits(maximumRetainedBytes: capacity, maximumTemporaryBytes: capacity,
            maximumDiagnosticBytes: diagnosticEnvelope, maximumWorkUnits: UInt64(parameterCapacity + 32768 + 4))
    }

    mutating func ordered(_ parameters: [String: Double]) throws -> [(String, Double)] {
        try charge()
        try check(Self.bytes(parameters.count, of: (String, Double).self))
        var ordered: [(String, Double)] = []
        ordered.reserveCapacity(parameters.count)
        try check(Self.bytes(ordered.capacity, of: (String, Double).self))
        for entry in parameters { ordered.append(entry) }
        ordered.sort { $0.0 < $1.0 }
        return ordered
    }

    mutating func diagnosticLines(_ messages: String, diagnosticStride: Int) throws -> [Substring] {
        try charge()
        guard UInt64(messages.utf8.count) <= limits.maximumDiagnosticBytes else { throw MOSPreparationFailure.capacityExceeded }
        var count = 1
        for byte in messages.utf8 where byte == 10 { count += 1 }
        let text = UInt64(messages.utf8.count)
        try check(Self.add(text, Self.bytes(count, of: Substring.self)))
        var lines: [Substring] = []
        lines.reserveCapacity(count)
        try check(Self.add(text, Self.bytes(lines.capacity, of: Substring.self)))
        var start = messages.startIndex
        var cursor = start
        while cursor < messages.endIndex {
            if messages[cursor] == "\n" {
                if start < cursor { lines.append(messages[start..<cursor]) }
                start = messages.index(after: cursor)
            }
            cursor = messages.index(after: cursor)
        }
        if start < messages.endIndex { lines.append(messages[start..<messages.endIndex]) }
        try check(Self.add(text, Self.add(Self.bytes(lines.capacity, of: Substring.self), UInt64(lines.count * diagnosticStride) + text)))
        return lines
    }
}
