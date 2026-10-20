import Testing
import CircuiteFoundation
import OSDIContracts
import CoreSpiceOSDIContracts

@Suite(.timeLimit(.minutes(1)))
struct OSDISimulationParameterReceiptTests {
    private func receipt(_ parameters: [OSDISimulationParameter] = []) throws -> OSDIPreparationReceipt {
        let artifact = try ArtifactReference(digest: ContentDigest(algorithm: .sha256,
            hexadecimalValue: String(repeating: "a", count: 64)), byteCount: 1,
            descriptor: ArtifactDescriptor(role: .input, kind: .model, format: .raw))
        let binding = try OSDIModelBinding(modelName: "model", artifact: artifact, descriptorIndex: 0,
            expectedDescriptorName: "model", modelParameters: [])
        let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])
        let topology = try OSDIPreparedTopology(nodes: [], activeUnknownCount: 0, stateCount: 0)
        return try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 298.15,
            topology: topology, resolvedParameters: [], simulationParameters: parameters)
    }

    @Test func orderedTypedBitsAndUTF8AreReceiptIdentity() throws {
        let zero = try OSDISimulationParameter(name: "tnom", value: .real(0))
        let minusZero = try OSDISimulationParameter(name: "tnom", value: .real(-0.0))
        let text = try OSDISimulationParameter(name: "label", value: .string("é"))
        let decomposed = try OSDISimulationParameter(name: "label", value: .string("e\u{301}"))
        #expect(try receipt().simulationParameters.isEmpty)
        #expect(try receipt([zero]) != receipt([minusZero]))
        #expect(try receipt([text]) != receipt([decomposed]))
        #expect(try receipt([zero, text]) != receipt([text, zero]))
        #expect(try receipt([zero, text]) == receipt([zero, text]))
        let copy = try receipt([zero, text])
        #expect(copy.simulationParameters.count == 2)
        #expect(copy.effectiveTemperatureKelvin.bitPattern == Double(298.15).bitPattern)
        #expect(throws: OSDIIntegrationFailure.duplicateSimulationParameter(name: "tnom")) {
            try receipt([zero, minusZero])
        }
    }
}
