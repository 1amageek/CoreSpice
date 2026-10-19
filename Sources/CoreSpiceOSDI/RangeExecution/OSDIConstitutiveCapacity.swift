import CoreSpiceIR
import CoreSpiceCompile
import OSDIContracts

/// Checked logical payload bounds, separate from allocator overhead and RSS.
enum OSDIConstitutiveCapacity {
    static func add(_ a: Int, _ b: Int) throws -> Int {
        guard a >= 0, b >= 0 else { throw OSDIConstitutiveCaptureFailure.capacityExceeded }
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw OSDIConstitutiveCaptureFailure.capacityExceeded }; return value
    }
    static func multiply(_ a: Int, _ b: Int) throws -> Int {
        guard a >= 0, b >= 0 else { throw OSDIConstitutiveCaptureFailure.capacityExceeded }
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw OSDIConstitutiveCaptureFailure.capacityExceeded }; return value
    }
    static func integer(_ value: UInt64) throws -> Int {
        guard let value = Int(exactly: value) else { throw OSDIConstitutiveCaptureFailure.capacityExceeded }; return value
    }
    static func inventory(active: Int, raw: Int) throws -> Int {
        let activeBytes = try multiply(active, MemoryLayout<MNAVariable?>.stride + MemoryLayout<Int?>.stride + 4)
        let rawBytes = try multiply(raw, 2 * MemoryLayout<Int?>.stride)
        // Public quotient validation holds two dictionaries and the retained representative array.
        var buckets = 8
        let required = try multiply(active, 4)
        while buckets < required { buckets = try multiply(buckets, 2) }
        let tables = try multiply(buckets, 8 * (MemoryLayout<OSDINodeInfo>.stride + 2 * MemoryLayout<Int>.stride))
        return try add(add(activeBytes, rawBytes), add(tables, add(32 * MemoryLayout<Int>.stride, MemoryLayout<OSDIConstitutiveCaptureRetention>.stride)))
    }
    static func simulationValidation(_ parameters: [OSDISimulationParameter],
        control: any LinearSolverExecutionControlling) throws -> any Sendable {
        let count = parameters.count
        // The preparation constructor builds one name Set. Use the same declared
        // bucket/generation bound as adapter dictionaries; input strings stay shared.
        var buckets = 8
        let required = try multiply(count, 4)
        while buckets < required { buckets = try multiply(buckets, 2) }
        let bytes = try multiply(buckets, 4 * (MemoryLayout<String>.stride + MemoryLayout<UInt>.stride))
        let lease = try control.reserveStorage(byteCount: count == 0 ? 0 : bytes)
        var text = 0
        for parameter in parameters {
            try control.checkpoint(workUnits: 1)
            text = try add(text, parameter.name.utf8.count)
            for byte in parameter.name.utf8 {
                try control.checkpoint(workUnits: 1)
                guard byte < 128 else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
            }
        }
        // Hash each byte and conservatively compare every pair if collisions occur.
        // ASCII equality needs no Unicode-normalization scratch.
        try control.checkpoint(workUnits: add(count, multiply(add(count, 1), add(text, count))))
        return lease
    }
    static func helper(options: OSDIPrecisionOptions) throws -> Int {
        // Identity pools and GMP temporaries are inside arenaBytes, not a second allocation.
        // Parent and child mapping views share physical backing and count once here.
        try add(add(integer(options.maximumMappingBytes), integer(options.arenaBytes)),
            add(MemoryLayout<OSDIConstitutiveCapture>.stride,
                add(OSDIConstitutiveCaptureStorage.logicalStateBytes, OSDIConstitutiveCaptureCleanup.logicalStateBytes)))
    }
}
