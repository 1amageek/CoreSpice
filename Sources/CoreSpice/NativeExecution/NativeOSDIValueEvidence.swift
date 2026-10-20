import CircuiteFoundation
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR
import OSDIContracts

/// Bounds immutable foreign facts independently of executable model/workspace ownership.
internal enum NativeOSDIValueEvidence {
    static func byteCount(records: [NativeOSDIPreparationRecord],
                          resources: any SPICESourceResourceAccounting, controlledProgramBacking: Bool = false) throws -> UInt64 {
        guard !records.isEmpty else { return 0 }
        var count = Counter(resources: resources)
        // Full four-receipt preparation backing plus fixed construction coexistence.
        try count.addBytes(UInt64(8 * MemoryLayout<SPICESourceStorageReservation>.stride
            + MemoryLayout<Counter>.stride + MemoryLayout<NativeOSDIPreparationRecord>.stride))
        try count.array(records)
        for record in records {
            try resources.checkCancellation()
            try count.text(record.instanceName)
            try count.array(record.rawNodeGlobalRows)
            try count.receipt(record.receipt)
            if let precision = record.transientPrecision {
                let program = precision.program
                if !controlledProgramBacking {
                    // Legacy Arrays have no original controlled reservation and retain their actual capacity.
                    try count.array(program.programBytes)
                    try count.array(program.setupBytes)
                }
                // Controlled P/U backing stays under its original SDK lease; inspecting metadata
                // neither extracts a public Array nor reserves that shared payload a second time.
                try count.topology(program.topology)
                try count.reference(program.modelReference)
                try count.digest(program.programDigest)
                try count.digest(program.setupDigest)
                try count.digest(program.semanticProfile)
                try count.reference(precision.workerReference)
                try count.digest(precision.numericProfile)
            }
        }
        return count.bytes
    }

    private struct Counter {
        let resources: any SPICESourceResourceAccounting
        var bytes: UInt64 = 0

        mutating func addBytes(_ amount: UInt64) throws {
            let (next, overflow) = bytes.addingReportingOverflow(amount)
            guard !overflow else { throw SPICENativePreparationError.capacityExceeded }
            try resources.charge(.projectedBytes, units: amount)
            bytes = next
        }
        mutating func array<Element>(_ values: borrowing [Element]) throws {
            try resources.checkCancellation()
            try resources.charge(.retainedElements, units: UInt64(values.capacity))
            let (amount, overflow) = UInt64(values.capacity).multipliedReportingOverflow(by: UInt64(MemoryLayout<Element>.stride))
            guard !overflow else { throw SPICENativePreparationError.capacityExceeded }
            try addBytes(amount)
        }
        mutating func text(_ value: String) throws {
            try resources.checkCancellation()
            let amount = UInt64(value.utf8.count)
            try resources.charge(.lexicalBytes, units: amount)
            try addBytes(amount)
        }
        mutating func digest(_ value: ContentDigest) throws {
            try text(value.algorithm.rawValue)
            try text(value.hexadecimalValue)
        }
        mutating func reference(_ value: ArtifactReference) throws {
            try digest(value.digest)
            try text(value.descriptor.role.rawValue)
            try text(value.descriptor.kind.rawValue)
            try text(value.descriptor.format.rawValue)
        }
        mutating func value(_ value: OSDIParameterValue) throws {
            if case .string(let text) = value { try self.text(text) }
        }
        mutating func assignments(_ values: [OSDIParameterAssignment]) throws {
            try array(values)
            for assignment in values {
                try resources.checkCancellation()
                try text(assignment.name)
                try value(assignment.value)
            }
        }
        mutating func topology(_ value: OSDIPreparedTopology) throws {
            try array(value.nodes)
            for node in value.nodes {
                try resources.checkCancellation()
                try text(node.name)
                try text(node.units)
                try text(node.residualUnits)
            }
        }
        mutating func receipt(_ receipt: OSDIPreparationReceipt) throws {
            let resolved = receipt.resolved
            try text(resolved.binding.modelName)
            try text(resolved.binding.expectedDescriptorName)
            try reference(resolved.binding.artifact)
            try assignments(resolved.binding.modelParameters)
            try assignments(resolved.instanceParameters)
            try array(resolved.previousState)
            try topology(receipt.topology)
            try array(receipt.resolvedParameters)
            for fact in receipt.resolvedParameters {
                try resources.checkCancellation()
                try array(fact.parameter.names)
                for name in fact.parameter.names { try text(name) }
                try text(fact.parameter.description)
                try text(fact.parameter.units)
                try value(fact.value)
            }
        }
    }
}
