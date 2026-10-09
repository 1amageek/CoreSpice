/// Counts owned buffer element capacity and encoded text payload, excluding allocator metadata.
package struct MOSStorageBudget {
    package let maximumBytes: UInt64
    package let maximumSteps: UInt64
    package let control: (any MOSResolutionControlling)?
    package private(set) var bytes: UInt64 = 0
    package private(set) var peakBytes: UInt64 = 0
    package private(set) var steps: UInt64 = 0

    package init(maximumBytes: UInt64, maximumSteps: UInt64,
                 control: (any MOSResolutionControlling)? = nil) {
        self.maximumBytes = maximumBytes; self.maximumSteps = maximumSteps; self.control = control
    }
    package mutating func spend() throws(MOSResolutionFailure) {
        guard steps < maximumSteps else { throw .limitExceeded(.evaluationSteps) }
        try control?.checkCancellation()
        try control?.charge(.evaluationSteps, units: 1)
        steps += 1
    }
    package func checkAdding(_ amount: UInt64) throws(MOSResolutionFailure) {
        let (next, overflow) = bytes.addingReportingOverflow(amount)
        guard !overflow else { throw .arithmeticOverflow }
        guard next <= maximumBytes else { throw .limitExceeded(.retainedBytes) }
        try control?.checkCancellation()
    }
    package mutating func add(_ amount: UInt64) throws(MOSResolutionFailure) {
        try checkAdding(amount)
        try control?.charge(.retainedBytes, units: amount)
        bytes += amount; peakBytes = max(peakBytes, bytes)
    }
    package mutating func release(_ amount: UInt64) { bytes -= amount }
    package static func capacityBytes<Element>(_ capacity: Int, of: Element.Type) throws(MOSResolutionFailure) -> UInt64 {
        guard let count = UInt64(exactly: capacity) else { throw .arithmeticOverflow }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: UInt64(MemoryLayout<Element>.stride))
        guard !overflow else { throw .arithmeticOverflow }
        return bytes
    }
    package mutating func addArray<Element>(_ values: [Element]) throws(MOSResolutionFailure) {
        try add(Self.capacityBytes(values.capacity, of: Element.self))
    }
    package mutating func addText(_ text: String?) throws(MOSResolutionFailure) {
        guard let text else { return }
        for _ in text.utf8 { try spend(); try add(1) }
    }
    package mutating func addSource(_ source: MOSSourceOccurrence?) throws(MOSResolutionFailure) {
        guard let source else { return }
        try addText(source.captureID); try addText(source.path)
    }
    package static func growthBytes<Element>(_ values: [Element], required: Int) throws(MOSResolutionFailure) -> UInt64 {
        guard required > 0 else { return 0 }
        let requested: Int
        if required > values.capacity {
            let (doubled, overflow) = values.capacity.multipliedReportingOverflow(by: 2)
            requested = overflow ? required : max(required, doubled)
        } else { requested = values.capacity }
        return try capacityBytes(requested, of: Element.self)
    }
    package static func dictionaryGrowthBytes<Key: Hashable, Value>(_ values: [Key: Value], required: Int) throws(MOSResolutionFailure) -> UInt64 {
        try capacityBytes(max(required, values.capacity), of: (Key, Value).self)
    }
    /// Checks requested storage before reserve and actual capacity before mutation.
    /// Old plus new capacity is a conservative COW/growth peak, even for unique reuse.
    package mutating func reserve<Element>(_ values: inout [Element], required: Int) throws(MOSResolutionFailure) {
        guard required > 0 else { return }
        guard UInt64(required) <= maximumSteps - steps else { throw .limitExceeded(.evaluationSteps) }
        let requestedBytes = try Self.growthBytes(values, required: required)
        try checkAdding(requestedBytes)
        let oldBytes = try Self.capacityBytes(values.capacity, of: Element.self)
        let requested = Int(requestedBytes / UInt64(MemoryLayout<Element>.stride))
        values.reserveCapacity(requested)
        try add(Self.capacityBytes(values.capacity, of: Element.self))
        release(oldBytes)
    }
    package mutating func reserveSet<Element: Hashable>(_ values: inout Set<Element>, required: Int) throws(MOSResolutionFailure) {
        guard required > 0 else { return }
        guard UInt64(required) <= maximumSteps - steps else { throw .limitExceeded(.evaluationSteps) }
        try checkAdding(Self.capacityBytes(max(required, values.capacity), of: Element.self))
        let oldBytes = try Self.capacityBytes(values.capacity, of: Element.self)
        values.reserveCapacity(max(required, values.capacity))
        try add(Self.capacityBytes(values.capacity, of: Element.self))
        release(oldBytes)
    }
    package mutating func reserveDictionary<Key: Hashable, Value>(_ values: inout [Key: Value], required: Int) throws(MOSResolutionFailure) {
        guard required > 0 else { return }
        guard UInt64(required) <= maximumSteps - steps else { throw .limitExceeded(.evaluationSteps) }
        try checkAdding(Self.dictionaryGrowthBytes(values, required: required))
        let oldBytes = try Self.capacityBytes(values.capacity, of: (Key, Value).self)
        values.reserveCapacity(max(required, values.capacity))
        try add(Self.capacityBytes(values.capacity, of: (Key, Value).self))
        release(oldBytes)
    }
}
