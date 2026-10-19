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
        let general = ["tf", "pz", "sens", "sens-ac", "fourier"].contains(phase)
        schemaVersion = phase == "network" ? 5 : phase == "dc" ? 4 : phase == "op" ? 1 : general ? 3 : 2
        profile = phase == "network" ? "nativeOSDI.network.v5" : phase == "dc" ? "nativeOSDI.dc.v4" : phase == "op" ? "nativeOSDI.op.v1" : general ? "nativeOSDI.analysis.v3" : "nativeOSDI.analysis.v2"; self.phase = phase
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
    private func validate() throws {
        guard ((schemaVersion == 1 && profile == "nativeOSDI.op.v1" && phase == "op") || (schemaVersion == 2 && profile == "nativeOSDI.analysis.v2" && ["ac", "tran", "noise"].contains(phase)) || (schemaVersion == 3 && profile == "nativeOSDI.analysis.v3" && ["tf", "pz", "sens", "sens-ac", "fourier"].contains(phase)) || (schemaVersion == 4 && profile == "nativeOSDI.dc.v4" && phase == "dc") || (schemaVersion == 5 && profile == "nativeOSDI.network.v5" && phase == "network")),
              !instanceName.isEmpty, !modelName.isEmpty, descriptorIndex >= 0, !expectedDescriptorName.isEmpty,
              effectiveKelvin.isFinite, effectiveKelvin > 0, completedPointCount > 0, (phase != "op" || completedPointCount == 1),
              previousState.allSatisfy(\.isFinite),
              rawNodeGlobalRows.count == rawNodeNames.count,
              rawNodeUnits.count == rawNodeNames.count, rawEquationUnits.count == rawNodeNames.count,
              rawNodeGlobalRows.allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              Set(modelParameters.map(\.name)).count == modelParameters.count,
              Set(instanceParameters.map(\.name)).count == instanceParameters.count,
              modelParameters.allSatisfy({ $0.scope == "model" && $0.descriptorIndex == nil && $0.isGiven == nil }),
              instanceParameters.allSatisfy({ $0.scope == "instance" && $0.descriptorIndex == nil && $0.isGiven == nil }),
              resolvedParameters.allSatisfy({ $0.descriptorIndex != nil && $0.isGiven != nil }) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid completed OSDI identity, phase, units, mapping or parameter facts")
        }
        if schemaVersion == 4 {
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
}
