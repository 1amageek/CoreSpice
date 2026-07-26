import CoreSpiceIR
import Foundation

/// Expands a SPICE uniform distributed RC line into its canonical lumped network.
///
/// The expansion matches the SPICE3/ngspice symmetric geometric ladder. Keeping
/// this transformation in lowering lets every analysis reuse the existing
/// resistor, capacitor, and diode implementations without teaching the solver
/// about source-format-specific devices.
struct UniformRCExpander: Sendable {
    private static let maximumLumpCount = 100

    func expand(
        name: String,
        nodeNames: [String],
        parameters: [String: ParameterValue],
        into builder: inout Netlist
    ) throws {
        guard nodeNames.count == 3 else {
            throw LoweringError.invalidComponent(
                name: name,
                reason: "Uniform RC line requires positive, negative, and capacitance-reference nodes"
            )
        }

        let length = try requiredReal("l", in: parameters, component: name)
        let propagation = try real("k", in: parameters, component: name) ?? 1.5
        let maximumFrequency = try real("fmax", in: parameters, component: name) ?? 1.0e9
        let resistancePerLength = try real("rperl", in: parameters, component: name) ?? 1_000
        let capacitancePerLength = try real("cperl", in: parameters, component: name) ?? 1.0e-12
        let saturationCurrentPerLength = try real("isperl", in: parameters, component: name) ?? 0
        let diodeResistancePerLength = try real("rsperl", in: parameters, component: name) ?? 0
        let usesJunctionShunts = parameters["isperl"] != nil

        guard length > 0 else {
            throw invalid(name, "l", "must be positive")
        }
        guard propagation > 1 else {
            throw invalid(name, "k", "must be greater than one")
        }
        guard maximumFrequency > 0 else {
            throw invalid(name, "fmax", "must be positive")
        }
        guard resistancePerLength > 0 else {
            throw invalid(name, "rperl", "must be positive")
        }
        guard capacitancePerLength > 0 else {
            throw invalid(name, "cperl", "must be positive")
        }
        guard saturationCurrentPerLength >= 0 else {
            throw invalid(name, "isperl", "must be non-negative")
        }
        guard diodeResistancePerLength >= 0 else {
            throw invalid(name, "rsperl", "must be non-negative")
        }

        let totalResistance = length * resistancePerLength
        let totalCapacitance = length * capacitancePerLength
        let totalSaturationCurrent = length * saturationCurrentPerLength
        guard totalResistance.isFinite, totalCapacitance.isFinite,
              totalSaturationCurrent.isFinite else {
            throw LoweringError.invalidComponent(
                name: name,
                reason: "Uniform RC aggregate parameters must be finite"
            )
        }

        let lumpCount = try resolvedLumpCount(
            parameters: parameters,
            component: name,
            maximumFrequency: maximumFrequency,
            totalResistance: totalResistance,
            totalCapacitance: totalCapacitance,
            propagation: propagation
        )
        let propagationPower = pow(propagation, Double(lumpCount))
        let firstResistance = totalResistance * (propagation - 1)
            / (2 * propagationPower - 2)
        let firstCapacitance = totalCapacitance * (propagation - 1)
            / (pow(propagation, Double(lumpCount - 1)) * (propagation + 1) - 2)
        let firstSaturationCurrent = totalSaturationCurrent * (propagation - 1)
            / (pow(propagation, Double(lumpCount - 1)) * (propagation + 1) - 2)
        let diodeSeriesResistance = length * Double(lumpCount) * diodeResistancePerLength

        var leftNode = nodeNames[0]
        var rightNode = nodeNames[1]
        var scale = 1.0
        for index in 1...lumpCount {
            let highNode = "\(name)#hi\(index)"
            let lowNode = index == lumpCount ? highNode : "\(name)#lo\(index)"
            let resistance = scale * firstResistance
            let capacitance = scale * firstCapacitance

            try builder.addInstance(
                name: "\(name).rlo\(index)",
                typeName: "resistor",
                nodes: [leftNode, lowNode],
                parameters: ["r": .real(resistance)]
            )
            try builder.addInstance(
                name: "\(name).rhi\(index)",
                typeName: "resistor",
                nodes: [highNode, rightNode],
                parameters: ["r": .real(resistance)]
            )
            try addShunt(
                name: "\(name).lo\(index)",
                lineNode: lowNode,
                referenceNode: nodeNames[2],
                capacitance: capacitance,
                saturationCurrent: scale * firstSaturationCurrent,
                diodeSeriesResistance: diodeSeriesResistance / scale,
                usesJunctionShunt: usesJunctionShunts,
                into: &builder
            )
            if index != lumpCount {
                try addShunt(
                    name: "\(name).hi\(index)",
                    lineNode: highNode,
                    referenceNode: nodeNames[2],
                    capacitance: capacitance,
                    saturationCurrent: scale * firstSaturationCurrent,
                    diodeSeriesResistance: diodeSeriesResistance / scale,
                    usesJunctionShunt: usesJunctionShunts,
                    into: &builder
                )
            }

            scale *= propagation
            leftNode = lowNode
            rightNode = highNode
        }
    }

    private func resolvedLumpCount(
        parameters: [String: ParameterValue],
        component: String,
        maximumFrequency: Double,
        totalResistance: Double,
        totalCapacitance: Double,
        propagation: Double
    ) throws -> Int {
        if let declared = try real("n", in: parameters, component: component) {
            guard declared >= 1,
                  declared.rounded(.towardZero) == declared,
                  declared <= Double(Int.max) else {
                throw invalid(component, "n", "must be a positive integer")
            }
            let resolved = Int(declared)
            guard resolved <= Self.maximumLumpCount else {
                throw invalid(
                    component,
                    "n",
                    "must not exceed \(Self.maximumLumpCount) to keep expansion resource-bounded"
                )
            }
            return resolved
        }

        let normalizedFrequency =
            maximumFrequency * totalResistance * totalCapacitance * 2 * Double.pi
        guard normalizedFrequency.isFinite else {
            throw invalid(component, "fmax", "produces a non-finite automatic lump count")
        }
        guard normalizedFrequency >= 35 else {
            return 3
        }
        let taper = (propagation - 1) / propagation
        let estimated = log(normalizedFrequency * taper * taper) / log(propagation)
        guard estimated.isFinite, estimated < Double(Int.max) else {
            throw invalid(component, "n", "automatic lump count is not representable")
        }
        let resolved = max(3, Int(estimated))
        guard resolved <= Self.maximumLumpCount else {
            throw invalid(
                component,
                "n",
                "automatic lump count \(resolved) exceeds the resource limit \(Self.maximumLumpCount)"
            )
        }
        return resolved
    }

    private func addShunt(
        name: String,
        lineNode: String,
        referenceNode: String,
        capacitance: Double,
        saturationCurrent: Double,
        diodeSeriesResistance: Double,
        usesJunctionShunt: Bool,
        into builder: inout Netlist
    ) throws {
        guard usesJunctionShunt else {
            try builder.addInstance(
                name: "\(name).c",
                typeName: "capacitor",
                nodes: [lineNode, referenceNode],
                parameters: ["c": .real(capacitance)]
            )
            return
        }

        let shuntNode: String
        if diodeSeriesResistance > 0 {
            shuntNode = "\(name)#shunt"
            try builder.addInstance(
                name: "\(name).rs",
                typeName: "resistor",
                nodes: [lineNode, shuntNode],
                parameters: ["r": .real(diodeSeriesResistance)]
            )
        } else {
            shuntNode = lineNode
        }

        guard saturationCurrent > 0 else {
            try builder.addInstance(
                name: "\(name).c",
                typeName: "capacitor",
                nodes: [shuntNode, referenceNode],
                parameters: ["c": .real(capacitance)]
            )
            return
        }
        try builder.addInstance(
            name: "\(name).d",
            typeName: "diode",
            nodes: [shuntNode, referenceNode],
            parameters: [
                "is": .real(saturationCurrent),
                "cjo": .real(capacitance),
            ]
        )
    }

    private func requiredReal(
        _ key: String,
        in parameters: [String: ParameterValue],
        component: String
    ) throws -> Double {
        guard let value = try real(key, in: parameters, component: component) else {
            throw LoweringError.invalidComponent(
                name: component,
                reason: "Uniform RC parameter '\(key)' is required"
            )
        }
        return value
    }

    private func real(
        _ key: String,
        in parameters: [String: ParameterValue],
        component: String
    ) throws -> Double? {
        guard let parameter = parameters[key] else {
            return nil
        }
        guard case .real(let value) = parameter else {
            throw LoweringError.invalidComponent(
                name: component,
                reason: "Uniform RC parameter '\(key)' must be numeric"
            )
        }
        return value
    }

    private func invalid(_ component: String, _ parameter: String, _ reason: String) -> LoweringError {
        .invalidComponent(
            name: component,
            reason: "Uniform RC parameter '\(parameter)' \(reason)"
        )
    }
}
