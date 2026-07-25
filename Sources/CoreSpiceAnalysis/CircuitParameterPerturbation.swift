import CoreSpiceIR

struct CircuitParameterPerturbation: Sendable {
    let instanceIndex: Int
    let deviceName: String
    let parameterName: String
    let nominalValue: Double
    let delta: Double
    let perturbedInstance: Instance

    static func makeAll(
        instances: [Instance],
        fraction: Double,
        minimumDelta: Double
    ) throws -> [CircuitParameterPerturbation] {
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
                    delta: delta,
                    perturbedInstance: Instance(
                        name: instance.name,
                        typeName: instance.typeName,
                        nodes: instance.nodes,
                        parameters: parameters,
                        opticalNodes: instance.opticalNodes
                    )
                ))
            }
        }
        return result
    }
}
