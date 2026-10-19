import CoreSpiceIO
import CoreSpiceDiodeContracts

extension SPICENativeSimulation {
    internal func validateDiodeConditions(input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits) throws {
        guard limits.diodePreparationLimits != nil, let capabilities = limits.diodeAnalyses else {
            throw SPICENativePreparationError.diodePreparation(.invalidConditions)
        }
        let requested: DiodeAnalysisCapabilities
        switch input.configuration.analysis {
        case .op, .dc, .transferFunction: requested = [.dc]
        case .transient, .fourier: requested = [.dc, .transient]
        case .ac, .poleZero, .network: requested = [.dc, .ac]
        case .sensitivity(_, let ac): requested = ac == nil ? [.dc] : [.dc, .ac]
        case .noise: requested = [.dc, .ac, .noise]
        }
        guard capabilities.isSuperset(of: requested) else { throw SPICENativePreparationError.diodePreparation(.unsupportedAnalysis) }
    }
    internal func encodeDiodePolicy(_ limits: SPICENativeExecutionLimits, encoding: inout SPICEPreparationEncoding) throws {
        if let diode = limits.diodePreparationLimits {
            try encoding.integer(1)
            try encoding.integer(diode.maximumRetainedBytes); try encoding.integer(diode.maximumTemporaryBytes)
            try encoding.integer(diode.maximumWorkUnits)
        } else { try encoding.integer(0) }
        if let analyses = limits.diodeAnalyses {
            try encoding.integer(1); try encoding.integer(UInt64(analyses.rawValue))
        } else { try encoding.integer(0) }
    }
    internal func encodeDiode(_ receipt: DiodePreparationReceipt, input: PreparedSPICESimulation,
                              encoding: inout SPICEPreparationEncoding) throws {
        let identity = receipt.identity, resolved = identity.resolved
        guard let origin = try input.lowered.compiled.modelOrigin(for: resolved),
              let source = input.sources.first(where: { $0.binding.key == origin.captureID }) else {
            throw SPICENativePreparationError.unsupportedCapability("Diode source requires captured declaration identity")
        }
        try encoding.field("diode-preparation.v2")
        try encoding.field(source.binding.reference.digest.hexadecimalValue); try encoding.integer(source.binding.reference.byteCount)
        try encoding.integer(origin.occurrenceID?.rawValue ?? 0)
        try encoding.integer(origin.statementByteOffset ?? UInt64(origin.location.line))
        try encoding.integer(origin.statementOrdinal ?? UInt64(origin.ordinal))
        try encoding.integer(resolved.model.declaration.declaration)
        try encoding.integer(UInt64(resolved.model.declaration.scope))
        try encoding.integer(resolved.model.declaration.invocation); try encoding.integer(resolved.invocation)
        try encoding.integer(UInt64(resolved.scope)); try encoding.field(resolved.instance)
        try encoding.integer(resolved.profile == .coreDiodeV1 ? 1 : 2)
        try encoding.integer(UInt64(resolved.model.input.schemaIdentity.law.rawValue))
        try encoding.integer(UInt64(resolved.model.input.schemaIdentity.revision))
        try encoding.field(resolved.evaluatorVersion); try encoding.field(resolved.randomGeneratorVersion)
        try encoding.integer(resolved.seed)
        try encoding.integer(resolved.orderedAssignmentEvidence ? 1 : 0)
        try encoding.integer(resolved.model.orderedAssignmentEvidence ? 1 : 0)
        for index in 0..<12 {
            guard let id = DiodeModelParameterID(rawValue: index) else { continue }
            if let value = resolved.model.input.value(for: id) { try encoding.integer(1); try encoding.number(value) }
            else { try encoding.integer(0) }
            try encodeDiodeOrigin(resolved.model.input.origin(for: id), encoding: &encoding)
            try encoding.integer(resolved.model.input.disposition(for: id) == .active ? 1 : 0)
        }
        for index in 0..<5 {
            guard let id = DiodeInstanceParameterID(rawValue: index) else { continue }
            try encodeDiodeOrigin(resolved.input.origin(for: id), encoding: &encoding)
        }
        for value in [resolved.input.rawGeometry.area?.value, resolved.input.rawGeometry.perimeter?.value] {
            if let value { try encoding.integer(1); try encoding.number(value) } else { try encoding.integer(0) }
        }
        try encoding.number(resolved.input.geometry.areaFactor.value)
        try encoding.number(resolved.input.geometry.perimeter.value); try encoding.number(resolved.input.multiplicity.value)
        switch resolved.input.thermal {
        case .ambient: try encoding.integer(0)
        case .absolute(let t): try encoding.integer(1); try encoding.number(t.value)
        case .offset(let t): try encoding.integer(2); try encoding.number(t.value)
        }
        try encoding.integer(UInt64(identity.environment.contractVersion))
        try encoding.integer(identity.environment.ambientKelvinBits); try encoding.integer(identity.environment.nominalKelvinBits)
        try encoding.number(identity.effectiveTemperature.value); try encoding.field(identity.implementationIdentity)
        try encoding.integer(UInt64(identity.analyses.rawValue))
        try encoding.integer(UInt64(identity.anodeNodeID)); try encoding.integer(UInt64(identity.cathodeNodeID))
        try encoding.integer(receipt.retainedBytes); try encoding.integer(receipt.peakTemporaryBytes); try encoding.integer(receipt.workUnits)
    }
    private func encodeDiodeOrigin(_ origin: DiodeValueOrigin, encoding: inout SPICEPreparationEncoding) throws {
        switch origin {
        case .supplied: try encoding.integer(0)
        case .schemaDefault: try encoding.integer(1)
        case .environmentDefault: try encoding.integer(2)
        }
    }
}
