import CircuiteFoundation
import CoreSpiceParsedIR
import OSDIContracts

extension ExternalMOSNormalizationProfile {
    func digest(resources: any SPICESourceResourceAccounting, maximumBytes: UInt64) throws -> ContentDigest {
        try SPICEPreparationEncoding.digest(domain: "corespice.external-mos-profile.v1",
            maximumBytes: maximumBytes, resources: resources) { e in
            try e.field(label)
            try e.field(artifact.digest.algorithm.rawValue); try e.field(artifact.digest.hexadecimalValue)
            try e.integer(artifact.byteCount); try e.field(artifact.descriptor.role.rawValue)
            try e.field(artifact.descriptor.kind.rawValue); try e.field(artifact.descriptor.format.rawValue)
            let d = descriptor
            for value in [d.index, d.nodeCount, d.terminalCount, d.jacobianEntryCount, d.stateCount,
                          d.collapsibleCount, d.parameterCount, d.instanceParameterCount,
                          d.operatingPointCount, d.noiseSourceCount, d.instanceByteCount, d.modelByteCount] {
                try e.integer(UInt64(value))
            }
            try e.field(d.name)
            try e.integer(UInt64(parameters.count))
            for p in parameters {
                try e.integer(UInt64(p.index)); try e.integer(UInt64(p.kind.rawValue))
                try e.integer(UInt64(p.type.rawValue)); try e.integer(UInt64(p.arrayLength))
                try e.field(p.description); try e.field(p.units); try e.integer(UInt64(p.names.count))
                for name in p.names { try e.field(name) }
            }
            try e.integer(UInt64(bitPattern: Int64(sourceLevel)))
            try e.integer(UInt64(sourceVersions.count))
            for version in sourceVersions { try e.field(version) }
            try e.integer(UInt64(rules.count))
            for r in rules {
                try e.integer(UInt64(r.scope.rawValue)); try e.field(r.meaning.rawValue)
                try e.integer(r.nonnegative ? 1 : 0)
                switch r.scale {
                case .none: try e.field("none")
                case .length: try e.field("length")
                case .area: try e.field("area")
                }
                try e.integer(UInt64(r.sourceNames.count))
                for name in r.sourceNames { try e.field(name) }
                try e.integer(r.providerName == nil ? 0 : 1)
                if let name = r.providerName { try e.field(name) }
                try e.integer(r.requiredValue == nil ? 0 : 1)
                if let value = r.requiredValue { try e.integer(value.bitPattern) }
            }
            for assignments in [nmosAssignments, pmosAssignments] {
                try e.integer(UInt64(assignments.count))
                for a in assignments {
                    try e.field(a.name); try e.integer(UInt64(a.scope.rawValue))
                    switch a.value {
                    case .real(let value): try e.field("real"); try e.integer(value.bitPattern)
                    case .integer(let value): try e.field("integer"); try e.integer(UInt64(bitPattern: Int64(value)))
                    case .string(let value): try e.field("string"); try e.field(value)
                    }
                }
            }
            try e.integer(versionParameter == nil ? 0 : 1)
            if let name = versionParameter { try e.field(name) }
            try e.field(sourceWidth.rawValue); try e.field(selectionWidth.rawValue)
            try e.field(providerWidth.rawValue); try e.integer(omittedFingerCount == nil ? 0 : 1)
            if let value = omittedFingerCount { try e.integer(value.bitPattern) }
            try e.field(candidateOrder.rawValue); try e.field(duplicateModels.rawValue)
            try e.integer(endpointToleranceSI.bitPattern)
        }
    }
}
