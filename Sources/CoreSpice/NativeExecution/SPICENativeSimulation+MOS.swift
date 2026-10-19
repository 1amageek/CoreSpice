import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts

extension SPICENativeSimulation {
    internal func validateMOSConditions(input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits) throws {
        guard limits.mosPreparationLimits != nil, let conditions = limits.mosPreparationConditions else {
            throw SPICENativePreparationError.mosPreparation(.invalidConditions)
        }
        let configuration = input.configuration
        var capabilities: MOSAnalysisCapabilities = [.dc]
        switch configuration.analysis {
        case .transient, .fourier: capabilities.insert(.transient)
        case .ac, .poleZero, .network: capabilities.insert(.ac)
        case .noise: capabilities.formUnion([.ac, .noise])
        case .sensitivity(_, let sweep): if sweep != nil { capabilities.insert(.ac) }
        case .op, .dc, .transferFunction: break
        }
        let operating = try configuration.options.operatingConditions()
        guard conditions.ambientKelvin == operating.temperatureKelvin,
              conditions.nominalKelvin == operating.nominalTemperatureKelvin,
              conditions.analysisCapabilities == capabilities else {
            throw SPICENativePreparationError.mosPreparation(.invalidConditions)
        }
    }

    internal func encodeMOS(_ receipt: MOSPreparationReceipt, input: PreparedSPICESimulation,
                            encoding: inout SPICEPreparationEncoding) throws {
        let resolved = receipt.identity.resolved
        try encoding.field("mos-preparation.v2")
        try encodeSource(resolved.source, input: input, encoding: &encoding)
        if let source = resolved.instanceSource {
            try encoding.integer(1); try encodeSource(source, input: input, encoding: &encoding)
        } else { try encoding.integer(0) }
        try encoding.field(resolved.instance)
        try encoding.field(resolved.symbolNames[Int(resolved.selectedName.rawValue)])
        try encoding.field(resolved.polarity == .nmos ? "nmos" : "pmos")
        try encoding.field(resolved.release.rawValue); try encoding.field(resolved.release.exactVersion ?? "")
        try encoding.field(resolved.schema.release.rawValue); try encoding.integer(UInt64(resolved.schema.revision))
        try encodeParameters(resolved.modelCoefficients, symbols: resolved.symbolNames, encoding: &encoding)
        try encodeParameters(resolved.instanceParameters, symbols: resolved.symbolNames, encoding: &encoding)
        for value in [resolved.normalizedGeometry.length, resolved.normalizedGeometry.width,
                      resolved.normalizedGeometry.drainArea, resolved.normalizedGeometry.sourceArea,
                      resolved.normalizedGeometry.drainPerimeter, resolved.normalizedGeometry.sourcePerimeter,
                      resolved.selectionGeometry.length, resolved.selectionGeometry.width] {
            if let value { try encoding.integer(1); try encoding.number(value) }
            else { try encoding.integer(0) }
        }
        try encoding.number(resolved.geometryScale); try encoding.number(resolved.selectionGeometry.fingerDivisor)
        let conditions = receipt.identity.conditions
        try encoding.number(conditions.ambientKelvin); try encoding.number(conditions.nominalKelvin)
        try encoding.integer(UInt64(conditions.analysisCapabilities.rawValue))
        try encoding.field(receipt.identity.implementationIdentity)
        // The v2 classic topology is the fixed D/G/S/B four-port value.
        try encoding.integer(UInt64(receipt.topology.localNodeCount))
    }

    private func encodeSource(_ origin: MOSSourceOccurrence, input: PreparedSPICESimulation,
                              encoding: inout SPICEPreparationEncoding) throws {
        guard let capture = origin.captureID, let occurrence = origin.occurrenceID,
              let offset = origin.statementByteOffset, let ordinal = origin.statementOrdinal,
              let source = input.sources.first(where: { $0.binding.key == capture }) else {
            throw SPICENativePreparationError.unsupportedCapability("MOS source requires captured content and exact occurrence")
        }
        try encoding.field(source.binding.reference.digest.hexadecimalValue)
        try encoding.integer(source.binding.reference.byteCount)
        try encoding.integer(occurrence); try encoding.integer(offset); try encoding.integer(ordinal)
    }

    private func encodeParameters(_ parameters: [MOSNumericParameter], symbols: [String],
                                  encoding: inout SPICEPreparationEncoding) throws {
        try encoding.integer(UInt64(parameters.count))
        for parameter in parameters.sorted(by: { symbols[Int($0.symbol.rawValue)] < symbols[Int($1.symbol.rawValue)] }) {
            try encoding.field(symbols[Int(parameter.symbol.rawValue)]); try encoding.number(parameter.value)
        }
    }
}
