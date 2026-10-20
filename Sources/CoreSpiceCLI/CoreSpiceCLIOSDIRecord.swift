import CircuiteFoundation
import CircuiteFoundationFoundation
import CoreSpice
import Foundation
import OSDIContracts

/// Inspection-only projection of an actually completed native OSDI phase.
public struct CoreSpiceCLIOSDIRecord: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let profile: String
    public let phase: String
    public let phaseSchemaVersion: Int
    public let phaseProfile: String
    public let simulationParameters: [CoreSpiceCLIOSDISimulationParameterRecord]
    public let sourceName: String?
    public let sourcePointIndex: Int?
    public let sourceValueBits: UInt64?
    public var sourceValue: Double? { sourceValueBits.map(Double.init(bitPattern:)) }
    public let instanceName: String
    public let modelName: String
    public let artifact: ArtifactReference
    public let descriptorIndex: Int
    public let expectedDescriptorName: String
    public let modelParameters: [CoreSpiceCLIOSDIParameterRecord]
    public let instanceParameters: [CoreSpiceCLIOSDIParameterRecord]
    public let previousState: [Double]
    public let resolvedParameters: [CoreSpiceCLIOSDIParameterRecord]
    public let effectiveKelvin: Double
    public let rawNodeGlobalRows: [Int?]
    public let rawNodeNames: [String]
    public let rawNodeUnits: [String]
    public let rawEquationUnits: [String]
    public let completedPointCount: Int

    init(phase: String, completed: NativeOSDIPreparationRecord, completedPointCount: Int,
         sourceName: String? = nil, sourceValue: Double? = nil, sourcePointIndex: Int? = nil) throws {
        let receipt = completed.receipt, binding = receipt.resolved.binding
        guard let contract = Self.phaseContract(phase) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Unknown completed OSDI phase")
        }
        phaseSchemaVersion = contract.schema; phaseProfile = contract.profile
        simulationParameters = try receipt.simulationParameters.map { try .init($0) }
        schemaVersion = simulationParameters.isEmpty ? contract.schema : 6
        profile = simulationParameters.isEmpty ? contract.profile : "nativeOSDI.simulation-parameters.v6"
        self.phase = phase
        self.sourceName = sourceName; self.sourcePointIndex = sourcePointIndex; sourceValueBits = sourceValue?.bitPattern
        instanceName = completed.instanceName; modelName = binding.modelName; artifact = binding.artifact
        descriptorIndex = binding.descriptorIndex; expectedDescriptorName = binding.expectedDescriptorName
        modelParameters = binding.modelParameters.map { .init($0) }
        instanceParameters = receipt.resolved.instanceParameters.map { .init($0) }
        previousState = receipt.resolved.previousState
        resolvedParameters = try receipt.resolvedParameters.map { fact in
            guard let name = fact.parameter.names.first else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Parameter name is absent") }
            return .init(try OSDIParameterAssignment(name: name, scope: fact.scope, value: fact.value),
                descriptorIndex: fact.parameter.index, isGiven: fact.isGiven)
        }
        effectiveKelvin = receipt.effectiveTemperatureKelvin
        rawNodeGlobalRows = completed.rawNodeGlobalRows
        rawNodeNames = receipt.topology.nodes.map(\.name)
        rawNodeUnits = receipt.topology.nodes.map(\.units)
        rawEquationUnits = receipt.topology.nodes.map(\.residualUnits)
        self.completedPointCount = completedPointCount
        try validate()
    }

    private static func phaseContract(_ phase: String) -> (schema: Int, profile: String)? {
        switch phase {
        case "op": return (1, "nativeOSDI.op.v1")
        case "ac", "tran", "noise": return (2, "nativeOSDI.analysis.v2")
        case "tf", "pz", "sens", "sens-ac", "fourier": return (3, "nativeOSDI.analysis.v3")
        case "dc": return (4, "nativeOSDI.dc.v4")
        case "network": return (5, "nativeOSDI.network.v5")
        default: return nil
        }
    }

    private func validate() throws {
        guard let contract = Self.phaseContract(phase),
              phaseSchemaVersion == contract.schema, phaseProfile == contract.profile,
              ((schemaVersion == contract.schema && profile == contract.profile && simulationParameters.isEmpty) ||
               (schemaVersion == 6 && profile == "nativeOSDI.simulation-parameters.v6" && !simulationParameters.isEmpty)),
              !instanceName.isEmpty, !modelName.isEmpty, descriptorIndex >= 0, !expectedDescriptorName.isEmpty,
              effectiveKelvin.isFinite, effectiveKelvin > 0, completedPointCount > 0, (phase != "op" || completedPointCount == 1),
              previousState.allSatisfy(\.isFinite),
              rawNodeGlobalRows.count == rawNodeNames.count,
              rawNodeUnits.count == rawNodeNames.count, rawEquationUnits.count == rawNodeNames.count,
              rawNodeGlobalRows.allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              Set(simulationParameters.map(\.name)).count == simulationParameters.count,
              Set(modelParameters.map(\.name)).count == modelParameters.count,
              Set(instanceParameters.map(\.name)).count == instanceParameters.count,
              modelParameters.allSatisfy({ $0.scope == "model" && $0.descriptorIndex == nil && $0.isGiven == nil }),
              instanceParameters.allSatisfy({ $0.scope == "instance" && $0.descriptorIndex == nil && $0.isGiven == nil }),
              resolvedParameters.allSatisfy({ $0.descriptorIndex != nil && $0.isGiven != nil }) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid completed OSDI identity, phase, units, mapping or parameter facts")
        }
        if phaseSchemaVersion == 4 {
            guard sourceName?.isEmpty == false, sourcePointIndex.map({ $0 >= 0 }) == true,
                  sourceValue?.isFinite == true, completedPointCount == 1 else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing exact OSDI DC point identity")
            }
        } else if sourceName != nil || sourcePointIndex != nil || sourceValueBits != nil {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Spurious OSDI source point identity")
        }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); profile = try c.decode(String.self, forKey: .profile)
        if schemaVersion == 6 {
            phaseSchemaVersion = try c.decode(Int.self, forKey: .phaseSchemaVersion)
            phaseProfile = try c.decode(String.self, forKey: .phaseProfile)
            simulationParameters = try c.decode([CoreSpiceCLIOSDISimulationParameterRecord].self, forKey: .simulationParameters)
        } else {
            guard !c.contains(.phaseSchemaVersion), !c.contains(.phaseProfile), !c.contains(.simulationParameters) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Simulation extension requires model schema 6")
            }
            phaseSchemaVersion = schemaVersion; phaseProfile = profile; simulationParameters = []
        }
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        sourcePointIndex = try c.decodeIfPresent(Int.self, forKey: .sourcePointIndex)
        sourceValueBits = try c.decodeIfPresent(UInt64.self, forKey: .sourceValueBits)
        phase = try c.decode(String.self, forKey: .phase); instanceName = try c.decode(String.self, forKey: .instanceName)
        modelName = try c.decode(String.self, forKey: .modelName); artifact = try c.decode(ArtifactReference.self, forKey: .artifact)
        descriptorIndex = try c.decode(Int.self, forKey: .descriptorIndex)
        expectedDescriptorName = try c.decode(String.self, forKey: .expectedDescriptorName)
        modelParameters = try c.decode([CoreSpiceCLIOSDIParameterRecord].self, forKey: .modelParameters)
        instanceParameters = try c.decode([CoreSpiceCLIOSDIParameterRecord].self, forKey: .instanceParameters)
        previousState = try c.decode([Double].self, forKey: .previousState)
        resolvedParameters = try c.decode([CoreSpiceCLIOSDIParameterRecord].self, forKey: .resolvedParameters)
        effectiveKelvin = try c.decode(Double.self, forKey: .effectiveKelvin)
        rawNodeGlobalRows = try c.decode([Int?].self, forKey: .rawNodeGlobalRows)
        rawNodeNames = try c.decode([String].self, forKey: .rawNodeNames)
        rawNodeUnits = try c.decode([String].self, forKey: .rawNodeUnits)
        rawEquationUnits = try c.decode([String].self, forKey: .rawEquationUnits)
        completedPointCount = try c.decode(Int.self, forKey: .completedPointCount)
        try validate()
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profile, phase, phaseSchemaVersion, phaseProfile, simulationParameters
        case sourceName, sourcePointIndex, sourceValueBits, instanceName, modelName, artifact
        case descriptorIndex, expectedDescriptorName, modelParameters, instanceParameters
        case previousState, resolvedParameters, effectiveKelvin, rawNodeGlobalRows, rawNodeNames
        case rawNodeUnits, rawEquationUnits, completedPointCount
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(profile, forKey: .profile)
        try c.encode(phase, forKey: .phase)
        if schemaVersion == 6 {
            try c.encode(phaseSchemaVersion, forKey: .phaseSchemaVersion)
            try c.encode(phaseProfile, forKey: .phaseProfile)
            try c.encode(simulationParameters, forKey: .simulationParameters)
        }
        try c.encodeIfPresent(sourceName, forKey: .sourceName)
        try c.encodeIfPresent(sourcePointIndex, forKey: .sourcePointIndex)
        try c.encodeIfPresent(sourceValueBits, forKey: .sourceValueBits)
        try c.encode(instanceName, forKey: .instanceName); try c.encode(modelName, forKey: .modelName)
        try c.encode(artifact, forKey: .artifact); try c.encode(descriptorIndex, forKey: .descriptorIndex)
        try c.encode(expectedDescriptorName, forKey: .expectedDescriptorName)
        try c.encode(modelParameters, forKey: .modelParameters)
        try c.encode(instanceParameters, forKey: .instanceParameters)
        try c.encode(previousState, forKey: .previousState); try c.encode(resolvedParameters, forKey: .resolvedParameters)
        try c.encode(effectiveKelvin, forKey: .effectiveKelvin)
        try c.encode(rawNodeGlobalRows, forKey: .rawNodeGlobalRows); try c.encode(rawNodeNames, forKey: .rawNodeNames)
        try c.encode(rawNodeUnits, forKey: .rawNodeUnits); try c.encode(rawEquationUnits, forKey: .rawEquationUnits)
        try c.encode(completedPointCount, forKey: .completedPointCount)
    }

}
