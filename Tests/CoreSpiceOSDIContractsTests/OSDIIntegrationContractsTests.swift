import Testing
import CircuiteFoundation
import OSDIContracts
import CoreSpiceOSDIContracts
import CoreSpiceIR

@Suite("OSDI integration contracts")
struct OSDIIntegrationContractsTests {
    private func artifact(hex: String = "a") throws -> ArtifactReference {
        try ArtifactReference(
            digest: ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: hex, count: 64)),
            byteCount: 123,
            descriptor: ArtifactDescriptor(role: .input, kind: .model, format: .unknown))
    }

    private func binding(modelName: String = "foreign", descriptorIndex: Int = 0,
                         expectedDescriptorName: String = "descriptor",
                         parameters: [OSDIParameterAssignment] = []) throws -> OSDIModelBinding {
        try OSDIModelBinding(modelName: modelName, artifact: artifact(), descriptorIndex: descriptorIndex,
                             expectedDescriptorName: expectedDescriptorName, modelParameters: parameters)
    }

    private func topology(stateCount: Int = 1, name: String = "p") throws -> OSDIPreparedTopology {
        let nature = try OSDINatureReference(kind: 0, index: 0)
        let node = try OSDINodeInfo(index: 0, name: name, units: "V", residualUnits: "A", isFlow: false,
                                    unknownNature: nature, residualNature: nature, activeUnknownIndex: 0)
        return try OSDIPreparedTopology(nodes: [node], activeUnknownCount: 1, stateCount: stateCount)
    }

    private func fact(scope: OSDIParameterScope, given: Bool = true) throws -> OSDIResolvedParameter {
        let parameter = try OSDIParameterInfo(index: 0, names: ["scale"], kind: .instance,
                                              type: .real, arrayLength: 0)
        return try OSDIResolvedParameter(parameter: parameter, scope: scope, value: .real(2), isGiven: given)
    }

    @Test func rejectsInvalidSelectionAndScopeWithoutInferringTypes() throws {
        #expect(throws: OSDIIntegrationFailure.invalidModelName) { try binding(modelName: "") }
        #expect(throws: OSDIIntegrationFailure.invalidModelName) { try binding(modelName: "bad\0name") }
        #expect(throws: OSDIIntegrationFailure.invalidDescriptorSelection) { try binding(descriptorIndex: -1) }
        #expect(throws: OSDIIntegrationFailure.invalidDescriptorSelection) { try binding(expectedDescriptorName: "") }
        let model = try OSDIParameterAssignment(name: "selector", scope: .model, value: .integer(2))
        let instance = try OSDIParameterAssignment(name: "selector", scope: .instance, value: .real(2))
        #expect(throws: OSDIIntegrationFailure.wrongAssignmentScope(
            name: "selector", expected: .model, actual: .instance)) {
            try binding(parameters: [instance])
        }
        #expect(throws: OSDIIntegrationFailure.duplicateAssignment(name: "selector", scope: .model)) {
            try binding(parameters: [model, model])
        }
        let selected = try binding(parameters: [model])
        #expect(throws: OSDIIntegrationFailure.wrongAssignmentScope(
            name: "selector", expected: .instance, actual: .model)) {
            try OSDIResolvedInstance(binding: selected, instanceParameters: [model], previousState: [])
        }
        #expect(throws: OSDIIntegrationFailure.duplicateAssignment(name: "selector", scope: .instance)) {
            try OSDIResolvedInstance(binding: selected, instanceParameters: [instance, instance], previousState: [])
        }
        let resolved = try OSDIResolvedInstance(binding: selected, instanceParameters: [instance], previousState: [0])
        #expect(resolved.binding.modelParameters[0].value == .integer(2))
        #expect(resolved.instanceParameters[0].value == .real(2))
        #expect(throws: OSDIIntegrationFailure.invalidPreviousState) {
            try OSDIResolvedInstance(binding: selected, instanceParameters: [], previousState: [.nan])
        }
    }

    @Test func receiptChecksDimensionsAndPreservesDefaultAndInstanceFacts() throws {
        let resolved = try OSDIResolvedInstance(binding: binding(), instanceParameters: [], previousState: [0])
        let preparedTopology = try topology()
        let modelFact = try fact(scope: .model)
        let instanceFact = try fact(scope: .instance)
        let receipt = try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                                topology: preparedTopology,
                                                resolvedParameters: [modelFact, instanceFact])
        #expect(receipt.resolvedParameters.count == 2)
        #expect(throws: OSDIIntegrationFailure.invalidTemperature) {
            try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 0,
                                       topology: preparedTopology, resolvedParameters: [])
        }
        #expect(throws: OSDIIntegrationFailure.invalidTemperature) {
            try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: .infinity,
                                       topology: preparedTopology, resolvedParameters: [])
        }
        #expect(throws: OSDIIntegrationFailure.stateDimensionMismatch(expected: 0, actual: 1)) {
            try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                       topology: topology(stateCount: 0), resolvedParameters: [])
        }
        #expect(throws: OSDIIntegrationFailure.duplicateResolvedParameter(index: 0, scope: .model)) {
            try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                       topology: preparedTopology, resolvedParameters: [modelFact, modelFact])
        }
        #expect(throws: OSDIIntegrationFailure.duplicateResolvedParameter(index: 0, scope: .instance)) {
            try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                       topology: preparedTopology, resolvedParameters: [instanceFact, instanceFact])
        }
    }

    @Test func completeReceiptEqualityDistinguishesInputsAndSetupFacts() throws {
        let resolved = try OSDIResolvedInstance(binding: binding(), instanceParameters: [], previousState: [0])
        let preparedTopology = try topology()
        let modelFact = try fact(scope: .model)
        let receipt = try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                                topology: preparedTopology, resolvedParameters: [modelFact])
        #expect(receipt == (try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                                       topology: preparedTopology, resolvedParameters: [modelFact])))
        let otherBinding = try OSDIModelBinding(modelName: "foreign", artifact: artifact(hex: "b"), descriptorIndex: 0,
                                                expectedDescriptorName: "descriptor", modelParameters: [])
        let alternatives = [
            try OSDIResolvedInstance(binding: otherBinding, instanceParameters: [], previousState: [0]),
            try OSDIResolvedInstance(binding: binding(modelName: "other"), instanceParameters: [], previousState: [0]),
            try OSDIResolvedInstance(binding: binding(parameters: [
                OSDIParameterAssignment(name: "scale", scope: .model, value: .integer(3))]),
                                     instanceParameters: [], previousState: [0]),
            try OSDIResolvedInstance(binding: binding(descriptorIndex: 1), instanceParameters: [], previousState: [0]),
            try OSDIResolvedInstance(binding: binding(expectedDescriptorName: "other"), instanceParameters: [], previousState: [0]),
            try OSDIResolvedInstance(binding: binding(), instanceParameters: [], previousState: [1]),
            try OSDIResolvedInstance(binding: binding(), instanceParameters: [
                OSDIParameterAssignment(name: "scale", scope: .instance, value: .real(3))], previousState: [0])
        ]
        for alternative in alternatives {
            #expect(receipt != (try OSDIPreparationReceipt(resolved: alternative, effectiveTemperatureKelvin: 300,
                                                           topology: preparedTopology, resolvedParameters: [modelFact])))
        }
        #expect(receipt != (try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 301,
                                                       topology: preparedTopology, resolvedParameters: [modelFact])))
        #expect(receipt != (try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                                       topology: topology(name: "changed"), resolvedParameters: [modelFact])))
        #expect(receipt != (try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                                       topology: preparedTopology, resolvedParameters: [fact(scope: .model, given: false)])))
    }

    @Test func bothStagesSurviveNetlistReconstructionAndBranchResolution() throws {
        let resolved = try OSDIResolvedInstance(binding: binding(), instanceParameters: [], previousState: [0])
        let receipt = try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
                                                topology: topology(), resolvedParameters: [])
        var netlist = Netlist()
        let branch = netlist.branch(name: "Vbias")
        try netlist.addInstance(name: "Nresolved", typeName: "osdi", nodes: ["p"],
                                osdi: .resolved(resolved), referencedBranchNames: ["Vbias"])
        try netlist.addInstance(name: "Nprepared", typeName: "osdi", nodes: ["p"], opticalNodes: ["light"],
                                osdi: .prepared(receipt))
        let circuit = try netlist.build()
        #expect(circuit.instances[0].osdi == .resolved(resolved))
        #expect(circuit.instances[0].referencedBranches == [branch])
        #expect(circuit.instances[1].osdi == .prepared(receipt))
        #expect(circuit.instances[1].osdi?.resolved == resolved)
        #expect(circuit.instances[1].opticalNodes.count == 1)
    }
}
