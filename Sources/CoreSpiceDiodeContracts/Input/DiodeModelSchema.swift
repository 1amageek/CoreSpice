public struct DiodeModelSchema: Sendable, Hashable {
    public let law: DiodeModelLaw
    public var identity: DiodeSchemaIdentity { .init(law: law) }
    public init(law: DiodeModelLaw) { self.law = law }

    public func parameter(named name: String, role: DiodeParameterRole,
                          limits: DiodeInputLimits) throws(DiodeSchemaFailure) -> DiodeParameterDefinition {
        var count = 0
        for byte in name.utf8 {
            guard count < limits.maximumParameterNameBytes,
                  (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte == 95 else { throw .invalidParameterName }
            count += 1
        }
        guard count > 0 else { throw .invalidParameterName }
        let key = name.lowercased()
        if let id = lookup(key, role: role) { return definition(for: id) }
        if lookup(key, role: role == .model ? .instance : .model) != nil {
            throw .wrongRole(name: key, requested: role)
        }
        switch key {
        case "js", "jsw", "cj", "cj0", "cjsw", "mj", "pb", "php", "mjsw", "scalm",
             "tlev", "tlevc", "tref", "tnom_k", "perim", "off", "ic", "l", "w":
            throw .unsupportedParameter(name: key, role: role)
        default: throw .unknownParameter(name: key, role: role)
        }
    }

    private func lookup(_ key: String, role: DiodeParameterRole) -> DiodeParameterID? {
        switch role {
        case .model:
            return switch key {
            case "is": .model(.saturationCurrent)
            case "n": .model(.ideality)
            case "rs": .model(.seriesResistance)
            case "bv": .model(.breakdownVoltage)
            case "ibv": .model(.breakdownCurrent)
            case "cjo": .model(.junctionCapacitance)
            case "vj": .model(.junctionPotential)
            case "m": .model(.gradingCoefficient)
            case "tt": .model(.transitTime)
            case "eg": .model(.energyGap)
            case "xti": .model(.saturationTemperatureExponent)
            case "tnom": .model(.nominalTemperature)
            default: nil
            }
        case .instance:
            return switch key {
            case "area": .instance(.areaFactor)
            case "pj": .instance(.perimeter)
            case "m": .instance(.parallelMultiplicity)
            case "temp": .instance(.temperature)
            case "dtemp": .instance(.temperatureDelta)
            default: nil
            }
        }
    }

    func constantDefault(for id: DiodeParameterID) throws(DiodeSchemaFailure) -> Double {
        guard case .constant(let value) = definition(for: id).defaultValue else { throw .schemaUnavailable(law) }
        return value
    }

    public func definition(for id: DiodeParameterID) -> DiodeParameterDefinition {
        switch id {
        case .model(.saturationCurrent):
            .init(id: id, sourceName: "is", sourceUnit: .amperes, canonicalUnit: .amperes,
                  domain: .positive, defaultValue: .constant(1e-14))
        case .model(.ideality):
            .init(id: id, sourceName: "n", sourceUnit: .dimensionless, canonicalUnit: .dimensionless,
                  domain: .positive, defaultValue: .constant(1))
        case .model(.seriesResistance):
            .init(id: id, sourceName: "rs", sourceUnit: .ohms, canonicalUnit: .ohms,
                  domain: .nonNegative, defaultValue: .constant(0))
        case .model(.breakdownVoltage):
            .init(id: id, sourceName: "bv", sourceUnit: .volts, canonicalUnit: .volts,
                  domain: .positive, defaultValue: .disabled)
        case .model(.breakdownCurrent):
            .init(id: id, sourceName: "ibv", sourceUnit: .amperes, canonicalUnit: .amperes,
                  domain: .positive, defaultValue: .constant(1e-3))
        case .model(.junctionCapacitance):
            .init(id: id, sourceName: "cjo", sourceUnit: .farads, canonicalUnit: .farads,
                  domain: .nonNegative, defaultValue: .constant(0))
        case .model(.junctionPotential):
            .init(id: id, sourceName: "vj", sourceUnit: .volts, canonicalUnit: .volts,
                  domain: .positive, defaultValue: .constant(1))
        case .model(.gradingCoefficient):
            .init(id: id, sourceName: "m", sourceUnit: .dimensionless, canonicalUnit: .dimensionless,
                  domain: .grading, defaultValue: .constant(0.5))
        case .model(.transitTime):
            .init(id: id, sourceName: "tt", sourceUnit: .seconds, canonicalUnit: .seconds,
                  domain: .nonNegative, defaultValue: .constant(0))
        case .model(.energyGap):
            .init(id: id, sourceName: "eg", sourceUnit: .electronVolts, canonicalUnit: .electronVolts,
                  domain: .positive, defaultValue: .constant(1.11))
        case .model(.saturationTemperatureExponent):
            .init(id: id, sourceName: "xti", sourceUnit: .dimensionless, canonicalUnit: .dimensionless,
                  domain: .finite, defaultValue: .constant(3))
        case .model(.nominalTemperature):
            .init(id: id, sourceName: "tnom", sourceUnit: .celsius, canonicalUnit: .kelvin,
                  domain: .absoluteCelsius, defaultValue: .environmentNominal)
        case .instance(.areaFactor):
            .init(id: id, sourceName: "area", sourceUnit: .dimensionless, canonicalUnit: .dimensionless,
                  domain: .positive, defaultValue: .constant(1))
        case .instance(.perimeter):
            .init(id: id, sourceName: "pj", sourceUnit: .inputLength, canonicalUnit: .metres,
                  domain: .nonNegative, defaultValue: .constant(0))
        case .instance(.parallelMultiplicity):
            .init(id: id, sourceName: "m", sourceUnit: .dimensionless, canonicalUnit: .dimensionless,
                  domain: .positive, defaultValue: .constant(1))
        case .instance(.temperature):
            .init(id: id, sourceName: "temp", sourceUnit: .celsius, canonicalUnit: .kelvin,
                  domain: .absoluteCelsius, defaultValue: .environmentAmbient)
        case .instance(.temperatureDelta):
            .init(id: id, sourceName: "dtemp", sourceUnit: .temperatureDelta, canonicalUnit: .temperatureDelta,
                  domain: .finite, defaultValue: .constant(0))
    }
    }
}
