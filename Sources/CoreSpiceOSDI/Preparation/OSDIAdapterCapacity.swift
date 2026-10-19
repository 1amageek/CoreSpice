import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDIContracts
import OSDIContracts

/// Conservative logical storage admission; allocator overhead/RSS and S2-native bytes are separate.
package enum OSDIAdapterCapacity {
    static func initial(ir: CircuitIR) throws(OSDIAdapterFailure) -> UInt64 {
        var count = Counter()
        try count.add(64, stride: MemoryLayout<Int>.stride)
        try count.add(ir.instances.capacity, stride: MemoryLayout<Instance>.stride, factor: 4)
        try count.add(ir.instances.count, stride: MemoryLayout<OSDIPreparedDevice?>.stride, factor: 4)
        try count.add(ir.nodes.capacity, stride: MemoryLayout<Node>.stride, factor: 4)
        try count.add(ir.branches.capacity, stride: MemoryLayout<Branch>.stride, factor: 4)
        try count.addBytes(table(entries: ir.nodes.count, key: MemoryLayout<Node>.stride, value: 0))
        try count.addBytes(table(entries: ir.branches.count, key: MemoryLayout<Branch>.stride, value: 0))
        try count.addBytes(table(entries: ir.nodeNames.capacity, key: MemoryLayout<Node>.stride, value: MemoryLayout<String>.stride))
        try count.addBytes(table(entries: ir.branchNames.capacity, key: MemoryLayout<Branch>.stride, value: MemoryLayout<String>.stride))
        return count.bytes
    }

    static func noiseNames(_ sources: [OSDINoiseSourceInfo]) throws(OSDIAdapterFailure) -> UInt64 {
        var count = Counter()
        for source in sources { try count.add(source.name.utf8.count, stride: 1, factor: 2) }
        return count.bytes
    }

    static func instance(nodeCount: Int, stateCount: Int, noiseSourceCount: Int = 0) throws(OSDIAdapterFailure) -> UInt64 {
        guard nodeCount >= 0, stateCount >= 0, noiseSourceCount >= 0 else { throw .capacityExceeded }
        let (square, overflow) = nodeCount.multipliedReportingOverflow(by: nodeCount)
        guard !overflow else { throw .capacityExceeded }
        var count = Counter()
        try count.add(64, stride: MemoryLayout<Int>.stride)
        try count.add(1, stride: OSDIExecutionOwner.logicalStateByteCount)
        try count.add(1, stride: MemoryLayout<OSDIPreparedDevice>.stride)
        try count.add(1, stride: MemoryLayout<OSDIPreparationReceipt>.stride)
        try count.add(1, stride: MemoryLayout<OSDIBoundMapping>.stride)
        // Projection, construction scratch, bound mapping and the fixed evaluation input buffer.
        try count.add(nodeCount, stride: MemoryLayout<MNAVariable?>.stride, factor: 3)
        try count.add(nodeCount, stride: MemoryLayout<Int?>.stride, factor: 4)
        try count.add(nodeCount, stride: MemoryLayout<OSDIVariableKind>.stride)
        try count.add(nodeCount, stride: MemoryLayout<OSDIVariableKind?>.stride)
        try count.add(nodeCount, stride: MemoryLayout<Bool>.stride)
        // Active input/accepted/facts coordinates, accepted/trial Q/Iq/F and owned same-trial F/Q.
        try count.add(nodeCount, stride: MemoryLayout<Double>.stride, factor: 11)
        try count.add(stateCount, stride: MemoryLayout<Double>.stride, factor: 3)
        try count.add(noiseSourceCount, stride: MemoryLayout<ResidualNoiseSource>.stride, factor: 4)
        try count.add(noiseSourceCount, stride: 32, factor: 2)
        try count.addBytes(table(entries: noiseSourceCount, key: MemoryLayout<Int>.stride, value: 0))
        try count.add(nodeCount, stride: MemoryLayout<Node>.stride, factor: 6)
        try count.add(nodeCount, stride: MemoryLayout<Branch>.stride, factor: 6)
        try count.add(nodeCount, stride: 32, factor: 2) // Bounded generated ASCII names and one temporary name.
        try count.add(square, stride: MemoryLayout<Int?>.stride)
        // Both simultaneously live CSR pair/slot maps, identity validation and variable-kind storage.
        try count.addBytes(table(entries: square, key: MemoryLayout<Int>.stride, value: MemoryLayout<Int>.stride))
        try count.addBytes(table(entries: square, key: MemoryLayout<Int>.stride, value: MemoryLayout<Int>.stride))
        try count.addBytes(table(entries: nodeCount, key: MemoryLayout<Int>.stride, value: MemoryLayout<MNAVariable>.stride))
        try count.addBytes(table(entries: nodeCount, key: MemoryLayout<MNAVariable>.stride, value: MemoryLayout<OSDIVariableKind>.stride))
        try count.addBytes(table(entries: nodeCount, key: MemoryLayout<Node>.stride, value: MemoryLayout<String>.stride))
        try count.addBytes(table(entries: nodeCount, key: MemoryLayout<Branch>.stride, value: MemoryLayout<String>.stride))
        return count.bytes
    }

    package static func precision(nodeCount: Int, options: OSDIPrecisionOptions) throws(OSDIAdapterFailure) -> UInt64 {
        var count = Counter()
        // Candidate/accepted low, accepted/trial Iq/F, plus facts candidate-low and F/delta-Q low/radius.
        try count.add(nodeCount, stride: MemoryLayout<Double>.stride, factor: 19)
        try count.add(1, stride: MemoryLayout<OSDITransientPrecisionReceipt>.stride)
        try count.addBytes(options.maximumProgramBytes)
        try count.addBytes(options.maximumMappingBytes)
        return count.bytes
    }

    private static func table(entries: Int, key: Int, value: Int) throws(OSDIAdapterFailure) -> UInt64 {
        guard entries >= 0 else { throw .capacityExceeded }
        if entries == 0 { return 0 }
        let (requested, overflow) = entries.multipliedReportingOverflow(by: 4)
        guard !overflow else { throw .capacityExceeded }
        var buckets = 8
        while buckets < requested {
            let (next, overflow) = buckets.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw .capacityExceeded }; buckets = next
        }
        var count = Counter()
        // Four table generations cover aggregate rounding, original COW storage and rehash scratch.
        try count.add(buckets, stride: key + value + MemoryLayout<UInt>.stride, factor: 4)
        try count.add(16, stride: MemoryLayout<Int>.stride)
        return count.bytes
    }

    private struct Counter {
        var bytes: UInt64 = 0
        mutating func add(_ count: Int, stride: Int, factor: Int = 1) throws(OSDIAdapterFailure) {
            guard count >= 0, stride >= 0, factor > 0 else { throw .capacityExceeded }
            let (elements, first) = UInt64(count).multipliedReportingOverflow(by: UInt64(stride))
            let (value, second) = elements.multipliedReportingOverflow(by: UInt64(factor))
            guard !first, !second else { throw .capacityExceeded }
            try addBytes(value)
        }
        mutating func addBytes(_ value: UInt64) throws(OSDIAdapterFailure) {
            let (sum, overflow) = bytes.addingReportingOverflow(value)
            guard !overflow else { throw .capacityExceeded }; bytes = sum
        }
    }
}
