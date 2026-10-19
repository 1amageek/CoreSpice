import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceDiodeContracts

struct CircuitParameterPerturbation: Sendable {
    let instanceIndex: Int
    let deviceName: String
    let parameterName: String
    let nominalValue: Double
    let perturbedValue: Double
    let effectiveIncrement: CompensatedValue
    let perturbedInstance: Instance

    static func makeAll(
        instances: [Instance],
        fraction: Double,
        minimumDelta: Double,
        cancellation: CancellationToken? = nil
    ) throws -> [CircuitParameterPerturbation] {
        // Ordinary IR rebinding cannot re-resolve immutable MOS inputs; source-backed callers use makeSourceResolved.
        if let instance = instances.first(where: { $0.mos != nil }) {
            throw AnalysisError.requiresFreshMOSResolution(instance: instance.name)
        }
        guard fraction.isFinite, fraction > 0 else {
            throw AnalysisError.invalidConfiguration(
                "Sensitivity perturbation fraction must be positive and finite"
            )
        }
        guard minimumDelta.isFinite, minimumDelta > 0 else {
            throw AnalysisError.invalidConfiguration(
                "Sensitivity minimum perturbation must be positive and finite"
            )
        }

        var result: [CircuitParameterPerturbation] = []
        for (instanceIndex, instance) in instances.enumerated() {
            if Task.isCancelled || cancellation?.isCancelled == true { throw AnalysisError.cancelled }
            if let resolved = instance.diode?.resolved {
                let schema = DiodeModelSchema(law: resolved.model.input.schemaIdentity.law)
                var inputs: [(DiodeParameterID, Double)] = []
                for index in 0..<12 {
                    if let id = DiodeModelParameterID(rawValue: index),
                       resolved.model.input.origin(for: id) == .supplied,
                       resolved.model.input.disposition(for: id) == .active,
                       let value = resolved.model.input.value(for: id) { inputs.append((.model(id), value)) }
                }
                for index in 0..<5 {
                    if let id = DiodeInstanceParameterID(rawValue: index), resolved.input.origin(for: id) == .supplied,
                       let value = DiodeNumericPerturbation.instanceValue(resolved.input, id: id) { inputs.append((.instance(id), value)) }
                }
                for (parameter, nominal) in inputs {
                    let delta = max(abs(nominal) * fraction, minimumDelta)
                    let replacement = nominal + delta
                    guard replacement.isFinite, replacement != nominal else {
                        throw AnalysisError.invalidConfiguration("Diode sensitivity perturbation is not representable")
                    }
                    let checked = try DiodeNumericPerturbation(basis: resolved, parameter: parameter, value: replacement)
                    let role = parameter.role == .model ? "model" : "instance"
                    let name = role + "." + schema.definition(for: parameter).sourceName
                    result.append(.init(instanceIndex: instanceIndex, deviceName: instance.name,
                        parameterName: name, nominalValue: nominal, perturbedValue: replacement,
                        effectiveIncrement: try CompensatedValue(high: replacement).subtracting(CompensatedValue(high: nominal)),
                        perturbedInstance: Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                            parameters: instance.parameters, model: instance.model, mos: instance.mos,
                            diode: .resolved(checked.resolved), osdi: instance.osdi, modelConsumption: instance.modelConsumption,
                            ownedNodes: instance.ownedNodes, ownedBranches: instance.ownedBranches,
                            referencedBranches: instance.referencedBranches, referencedNodes: instance.referencedNodes,
                            opticalNodes: instance.opticalNodes)))
                }
                continue
            }
            for parameterName in instance.parameters.keys.sorted() {
                guard case .real(let nominalValue) = instance.parameters[parameterName] else {
                    continue
                }
                guard nominalValue.isFinite else {
                    throw AnalysisError.invalidConfiguration(
                        "Sensitivity parameter \(instance.name).\(parameterName) must be finite"
                    )
                }
                let delta = max(abs(nominalValue) * fraction, minimumDelta)
                let perturbedValue = nominalValue + delta
                guard perturbedValue.isFinite, perturbedValue != nominalValue else {
                    throw AnalysisError.invalidConfiguration(
                        "Sensitivity perturbation for \(instance.name).\(parameterName) is not representable"
                    )
                }

                var parameters = instance.parameters
                parameters[parameterName] = .real(perturbedValue)
                result.append(CircuitParameterPerturbation(
                    instanceIndex: instanceIndex,
                    deviceName: instance.name,
                    parameterName: parameterName,
                    nominalValue: nominalValue,
                    perturbedValue: perturbedValue,
                    effectiveIncrement: try CompensatedValue(high: perturbedValue).subtracting(CompensatedValue(high: nominalValue)),
                    perturbedInstance: Instance(
                        name: instance.name,
                        typeName: instance.typeName,
                        nodes: instance.nodes,
                        parameters: parameters,
                        model: instance.model,
                        mos: instance.mos, diode: instance.diode, osdi: instance.osdi, modelConsumption: instance.modelConsumption,
                        ownedNodes: instance.ownedNodes,
                        ownedBranches: instance.ownedBranches,
                        referencedBranches: instance.referencedBranches,
                        referencedNodes: instance.referencedNodes,
                        opticalNodes: instance.opticalNodes
                    )
                ))
            }
        }
        return result
    }

    static func makeSourceResolved(
        parameters: [CircuitSensitivityParameter],
        instances: [Instance], fraction: Double, minimumDelta: Double,
        cancellation: CancellationToken
    ) throws -> [CircuitParameterPerturbation] {
        guard fraction.isFinite, fraction > 0, minimumDelta.isFinite, minimumDelta > 0 else {
            throw AnalysisError.invalidConfiguration("Sensitivity perturbation bounds must be positive and finite")
        }
        var result: [CircuitParameterPerturbation] = []
        var seen = Set<String>()
        for parameter in parameters {
            if Task.isCancelled || cancellation.isCancelled { throw AnalysisError.cancelled }
            let matches = instances.indices.filter {
                instances[$0].name.lowercased() == parameter.deviceName.lowercased()
            }
            guard matches.count == 1, let index = matches.first,
                  !parameter.parameterName.isEmpty, parameter.nominalValue.isFinite,
                  seen.insert(parameter.deviceName.lowercased() + "\u{0}" + parameter.parameterName).inserted else {
                throw AnalysisError.invalidConfiguration("Source sensitivity parameter identity is invalid or ambiguous")
            }
            let nominal = parameter.nominalValue
            let delta = max(abs(nominal) * fraction, minimumDelta)
            let value = nominal + delta
            guard value.isFinite, value != nominal else {
                throw AnalysisError.invalidConfiguration("Source sensitivity perturbation is not representable")
            }
            let instance = instances[index]
            var values = instance.parameters
            values[parameter.parameterName] = .real(value)
            let replacement = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                parameters: values, model: instance.model, mos: instance.mos, diode: instance.diode,
                osdi: instance.osdi, modelConsumption: instance.modelConsumption, ownedNodes: instance.ownedNodes,
                ownedBranches: instance.ownedBranches, referencedBranches: instance.referencedBranches,
                referencedNodes: instance.referencedNodes, opticalNodes: instance.opticalNodes)
            result.append(.init(instanceIndex: index, deviceName: instance.name,
                parameterName: parameter.parameterName, nominalValue: nominal, perturbedValue: value,
                effectiveIncrement: try CompensatedValue(high: value).subtracting(CompensatedValue(high: nominal)),
                perturbedInstance: replacement))
        }
        return result
    }

}
