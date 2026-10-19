import CoreSpiceLowering
import OSDIContracts

extension SPICEPreparationEncoding {
    /// Binds checked source preparation, not provider implementation pointers or availability paths.
    package mutating func encodeExternalMOS(_ preparations: [CheckedExternalMOSPreparation]) throws {
        try field("external-original-m.checked-source.v1")
        try integer(UInt64(preparations.count))
        for checked in preparations {
            let result = checked.preparation, source = result.source
            try field(source.resolution.instance)
            try field(source.original.type.rawValue)
            try integer(UInt64(source.resolution.scope.rawValue))
            try integer(source.resolution.scopeInstantiation)
            try integer(UInt64(source.candidateScope.rawValue)); try integer(source.candidateInvocation)
            try integer(source.isFamily ? 1 : 0)
            try integer(UInt64(source.candidateDeclarations.count))
            for candidate in source.candidateDeclarations { try integer(UInt64(candidate.rawValue)) }
            try integer(UInt64(result.selectedDeclaration.rawValue))
            try field(result.facts.profileIdentity)
            try integer(UInt64(source.terminals.count))
            for terminal in source.terminals { try field(terminal) }
            try number(source.resolution.geometryScale)
            try integer(source.resolution.globalWidthPerFinger ? 1 : 0)
            let geometry = result.facts.geometry
            try optionalExternalNumber(geometry.rawLength); try optionalExternalNumber(geometry.rawWidth)
            for value in [geometry.effectiveLengthSI, geometry.totalWidthSI, geometry.selectionLengthSI,
                          geometry.selectionWidthSI, geometry.fingerCount, geometry.parallelMultiplier] { try number(value) }
            try integer(geometry.widthInputIsPerFinger ? 1 : 0)
            try integer(UInt64(checked.evaluatedScalars.count))
            for scalar in checked.evaluatedScalars { try externalAddress(scalar.address); try number(scalar.value) }
            try integer(UInt64(result.facts.parameters.count))
            for fact in result.facts.parameters {
                if let address = fact.address { try integer(1); try externalAddress(address) }
                else { try integer(0) }
                try field(fact.name); try field(fact.role == .model ? "model" : "instance")
                try optionalExternalNumber(fact.rawValue); try optionalExternalNumber(fact.normalizedValue)
                try integer(fact.isGiven ? 1 : 0)
                if let value = fact.providerValue { try integer(1); try externalValue(value) }
                else { try integer(0) }
            }
            let resolved = result.resolved, binding = resolved.binding
            try field(binding.modelName); try field(binding.artifact.digest.algorithm.rawValue)
            try field(binding.artifact.digest.hexadecimalValue); try integer(binding.artifact.byteCount)
            try field(binding.artifact.descriptor.role.rawValue); try field(binding.artifact.descriptor.kind.rawValue)
            try field(binding.artifact.descriptor.format.rawValue)
            try integer(UInt64(binding.descriptorIndex)); try field(binding.expectedDescriptorName)
            for assignments in [binding.modelParameters, resolved.instanceParameters] {
                try integer(UInt64(assignments.count))
                for assignment in assignments {
                    try field(assignment.name); try field(assignment.scope == .model ? "model" : "instance")
                    try externalValue(assignment.value)
                }
            }
            try integer(UInt64(resolved.previousState.count))
            for value in resolved.previousState { try number(value) }
        }
    }
    private mutating func optionalExternalNumber(_ value: Double?) throws {
        if let value { try integer(1); try number(value) } else { try integer(0) }
    }
    private mutating func externalAddress(_ address: ExternalMOSScalarAddress) throws {
        switch address {
        case .instance(let index): try field("instance"); try integer(UInt64(index))
        case .model(let declaration, let index):
            try field("model"); try integer(UInt64(declaration.rawValue)); try integer(UInt64(index))
        case .modelOverride(let index): try field("model-override"); try integer(UInt64(index))
        }
    }
    private mutating func externalValue(_ value: OSDIParameterValue) throws {
        switch value {
        case .real(let value): try field("real"); try number(value)
        case .integer(let value): try field("integer"); try integer(UInt64(UInt32(bitPattern: value)))
        case .string(let value): try field("string"); try field(value)
        }
    }
}
