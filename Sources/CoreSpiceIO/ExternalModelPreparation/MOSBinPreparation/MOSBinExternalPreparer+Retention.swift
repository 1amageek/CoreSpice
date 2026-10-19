import CoreSpiceParsedIR
import OSDIContracts

extension MOSBinExternalPreparer {
    /// Logical retention accounting; shared COW backing is not a claim of unique RSS.
    static func retainedProfileBytes(_ p: ExternalMOSNormalizationProfile) throws -> UInt64 {
        var bytes = UInt64(MemoryLayout<Self>.stride)
        func add(_ count: Int, stride: Int = 1) throws {
            guard count >= 0, stride >= 0 else { throw MOSBinPreparationError.sizeOverflow }
            let (size, multiplicationOverflow) = UInt64(count).multipliedReportingOverflow(by: UInt64(stride))
            let (next, additionOverflow) = bytes.addingReportingOverflow(size)
            guard !multiplicationOverflow, !additionOverflow else { throw MOSBinPreparationError.sizeOverflow }
            bytes = next
        }
        func text(_ value: String) throws { try add(value.utf8.count) }
        func names(_ values: [String]) throws {
            try add(values.capacity, stride: MemoryLayout<String>.stride)
            for value in values { try text(value) }
        }
        try text(p.label); try text(p.descriptor.name)
        try text(p.artifact.digest.algorithm.rawValue); try text(p.artifact.digest.hexadecimalValue)
        try text(p.artifact.descriptor.role.rawValue); try text(p.artifact.descriptor.kind.rawValue)
        try text(p.artifact.descriptor.format.rawValue)
        try names(p.sourceVersions)
        try add(p.parameters.capacity, stride: MemoryLayout<OSDIParameterInfo>.stride)
        for parameter in p.parameters {
            try names(parameter.names); try text(parameter.description); try text(parameter.units)
        }
        try add(p.rules.capacity, stride: MemoryLayout<ExternalMOSParameterRule>.stride)
        for rule in p.rules {
            try names(rule.sourceNames)
            if let name = rule.providerName { try text(name) }
        }
        func assignments(_ values: [OSDIParameterAssignment]) throws {
            try add(values.capacity, stride: MemoryLayout<OSDIParameterAssignment>.stride)
            for assignment in values {
                try text(assignment.name)
                if case .string(let value) = assignment.value { try text(value) }
            }
        }
        try assignments(p.nmosAssignments); try assignments(p.pmosAssignments)
        if let name = p.versionParameter { try text(name) }
        // SHA-256 always has 64 hexadecimal bytes; the stored String header is
        // already included in Self.stride, and both text payloads are admitted.
        try add("external-mos-profile-v1:".utf8.count + 64)
        return bytes
    }
}
