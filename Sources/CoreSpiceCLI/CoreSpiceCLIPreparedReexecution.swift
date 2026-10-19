import CoreSpice

/// Completed sensitivity child binding with its exact source patch and consumed model values.
struct CoreSpiceCLIPreparedReexecution: Codable, Sendable, Equatable {
    struct Scalar: Codable, Sendable, Equatable {
        let instance: String
        let role: String
        let parameter: String
        let value: Double
    }
    let deviceName: String
    let parameterName: String
    let nominalValue: Double
    let perturbedValue: Double
    let effectiveIncrement: CoreSpiceCLISensitivityEvidence.Sample
    let physicalAnalysis: String
    let outputNode: Int
    let referenceNode: Int?
    let frequencies: [Double]
    let observations: [CoreSpiceCLISensitivityEvidence.Sample]
    let sourceInputIdentity: String
    let configurationIdentity: String
    let selection: CoreSpiceCLIPreparedCase.Selection
    let sourceOverrides: [Scalar]
    let osdiPatchDescriptorIndex: Int?
    let osdiModels: [CoreSpiceCLIOSDIRecord]
    let mosModels: [CoreSpiceCLIPreparedMOSModel]
    let diodeModels: [CoreSpiceCLIDiodeRecord]

    init(_ record: SPICENativeSourceReexecutionCompletion, phase: String, completedPoints: Int) throws {
        deviceName = record.deviceName; parameterName = record.parameterName
        nominalValue = record.nominalValue; perturbedValue = record.perturbedValue
        effectiveIncrement = .init(record.effectiveIncrement)
        let completedAnalysis = record.completedPhase.analysis
        physicalAnalysis = completedAnalysis
        guard record.completedPhase.completedPointCount == completedPoints,
              phase == (completedAnalysis == "op" ? "sens" : "sens-ac") else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Sensitivity child physical completion differs")
        }
        switch record.observation {
        case .dc(let output, let node):
            outputNode = node.id; referenceNode = nil; frequencies = []; observations = [.init(output)]
        case .ac(let outputs, let coordinates, let positive, let reference):
            outputNode = positive.id; referenceNode = reference?.id; frequencies = coordinates
            observations = outputs.map { .init(real: $0.real, imaginary: $0.imag) }
        }
        sourceInputIdentity = record.sourceInputIdentity.hexadecimalValue
        configurationIdentity = record.configurationIdentity.hexadecimalValue
        selection = .init(record.configuration)
        sourceOverrides = record.sourceOverrides.map { .init(instance: $0.instanceName, role: $0.role.rawValue, parameter: $0.parameterName, value: $0.value) }
        if let selected = record.completedPhase.osdiPreparationRecords.first(where: {
            $0.instanceName.caseInsensitiveCompare(record.deviceName) == .orderedSame
        }) {
            let parts = record.parameterName.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("OSDI sensitivity scalar lacks its source role") }
            let matches = selected.receipt.resolvedParameters.filter { fact in
                let scope: String
                switch fact.scope { case .model: scope = "model"; case .instance: scope = "instance" }
                return scope == parts[0] && fact.parameter.names.contains { $0.caseInsensitiveCompare(parts[1]) == .orderedSame }
            }
            guard matches.count == 1, let fact = matches.first else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("OSDI sensitivity source alias lacks one actual descriptor")
            }
            osdiPatchDescriptorIndex = fact.parameter.index
        } else { osdiPatchDescriptorIndex = nil }
        osdiModels = try record.completedPhase.osdiPreparationRecords.map {
            try .init(phase: completedAnalysis, completed: $0, completedPointCount: completedPoints)
        }
        mosModels = try record.preparation.mosPreparationReceipts.map { try .init(phase: completedAnalysis, receipt: $0, completedPoints: completedPoints) }
        diodeModels = try record.preparation.diodePreparationReceipts.map { receipt in
            guard let modelName = record.selectedDiodeModels[receipt.identity.resolved.instance] else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Fresh sensitivity diode model identity is missing")
            }
            return .init(phase: completedAnalysis, receipt: receipt, modelName: modelName, completedPointCount: completedPoints)
        }
        try validate()
    }

    func validate() throws {
        try selection.validate()
        guard !deviceName.isEmpty, !parameterName.isEmpty, nominalValue.isFinite, perturbedValue.isFinite,
              ["op", "ac"].contains(physicalAnalysis), !observations.isEmpty,
              physicalAnalysis == "op" ? frequencies.isEmpty && observations.count == 1 : frequencies.count == observations.count else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete actual sensitivity child solve")
        }
        try effectiveIncrement.validate(complex: false)
        for value in observations { try value.validate(complex: physicalAnalysis == "ac") }
        guard [sourceInputIdentity, configurationIdentity].allSatisfy({ value in
                  value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }),
              sourceOverrides.allSatisfy({ !$0.instance.isEmpty && !$0.parameter.isEmpty && ["model", "instance"].contains($0.role) && $0.value.isFinite }) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete sensitivity source reexecution")
        }
        for model in mosModels { try model.validate() }
        try validateParameterPatch()
    }
    func validateParameterPatch() throws {
        let parts = parameterName.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["model", "instance"].contains(parts[0]) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Sensitivity scalar lacks its source role")
        }
        let selected = osdiModels.filter { $0.instanceName.caseInsensitiveCompare(deviceName) == .orderedSame }
        if !selected.isEmpty {
            guard selected.count == 1, let model = selected.first, let descriptor = osdiPatchDescriptorIndex,
                  descriptor >= 0, model.phase == physicalAnalysis, model.completedPointCount == observations.count else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("OSDI sensitivity descriptor or physical completion differs")
            }
            let assignments = parts[0] == "model" ? model.modelParameters : model.instanceParameters
            let source = assignments.filter { $0.scope == parts[0] && $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame }
            let consumed = model.resolvedParameters.filter { $0.scope == parts[0] && $0.descriptorIndex == descriptor }
            guard source.count == 1, consumed.count == 1, let assignment = source.first, let fact = consumed.first,
                  case .real(let sourceValue) = try assignment.assignment().value,
                  case .real(let consumedValue) = try fact.assignment().value,
                  sourceValue.bitPattern == perturbedValue.bitPattern, consumedValue.bitPattern == perturbedValue.bitPattern,
                  fact.isGiven == true else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("OSDI sensitivity typed source assignment or consumed value differs")
            }
        } else {
            guard osdiPatchDescriptorIndex == nil, sourceOverrides.contains(where: {
                $0.instance.caseInsensitiveCompare(deviceName) == .orderedSame && $0.role == parts[0] &&
                $0.parameter == parts[1] && $0.value.bitPattern == perturbedValue.bitPattern
            }) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Sensitivity child scalar override differs from the completed parameter") }
        }
    }

}
