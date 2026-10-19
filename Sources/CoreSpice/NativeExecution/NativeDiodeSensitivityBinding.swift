import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceDiodeContracts

/// Native invocation owns the additional fresh-binding and perturbation scratch envelope.
internal enum NativeDiodeSensitivityBinding {
    static func capacities(_ record: NativeCircuitPreparationRecord) throws -> (retained: UInt64, temporary: UInt64) {
        var retained: UInt64 = 0, temporary: UInt64 = 0
        for receipt in record.diodePreparationReceipts {
            let basis = receipt.identity.resolved
            let schema = DiodeModelSchema(law: basis.model.input.schemaIdentity.law)
            var count: UInt64 = 0, nameBytes: UInt64 = 0
            for index in 0..<12 {
                guard let id = DiodeModelParameterID(rawValue: index) else { continue }
                if basis.model.input.origin(for: id) == .supplied,
                   basis.model.input.disposition(for: id) == .active,
                   basis.model.input.value(for: id) != nil { count += 1 }
                nameBytes = try NativeCircuitExecution.capacitySum(nameBytes, UInt64(schema.definition(for: .model(id)).sourceName.utf8.count))
            }
            for index in 0..<5 {
                guard let id = DiodeInstanceParameterID(rawValue: index) else { continue }
                if basis.input.origin(for: id) == .supplied,
                   DiodeNumericPerturbation.instanceValue(basis.input,id: id) != nil { count += 1 }
                nameBytes = try NativeCircuitExecution.capacitySum(nameBytes, UInt64(schema.definition(for: .instance(id)).sourceName.utf8.count))
            }
            // Input scalars are inline. Each changed model owns a header/payload and
            // evaluator suffix. All variable-length identity payload is charged by UTF-8 extent.
            var strings = UInt64(".numeric-perturbation.v1".utf8.count)
            for text in [basis.instance, basis.evaluatorVersion, basis.randomGeneratorVersion,
                         basis.model.declaration.sourcePath ?? "", basis.model.declaration.captureID ?? "",
                         receipt.identity.implementationIdentity] {
                strings = try NativeCircuitExecution.capacitySum(strings, UInt64(text.utf8.count))
            }
            let clone = try NativeCircuitExecution.capacitySum(ResolvedDiodeModel.ownedByteCount,
                NativeCircuitExecution.capacityProduct(strings, 2))
            let resultEntry = UInt64(max(MemoryLayout<SensitivityResult.ParameterSensitivity>.stride,
                MemoryLayout<ACSensitivityResult.ParameterSensitivity>.stride) + MemoryLayout<DiodePreparationReceipt>.stride)
            // Two arrays (result/facts), with growth coexistence; cloned model is shared.
            let returned = try NativeCircuitExecution.capacitySum(
                NativeCircuitExecution.capacitySum(clone, NativeCircuitExecution.capacityProduct(nameBytes + 7, 2)),
                NativeCircuitExecution.capacityProduct(resultEntry, 2))
            retained = try NativeCircuitExecution.capacitySum(retained,
                NativeCircuitExecution.capacityProduct(count, returned))
            let item = try NativeCircuitExecution.capacitySum(clone,
                UInt64(MemoryLayout<Instance>.stride + MemoryLayout<DiodeNumericPerturbation>.stride))
            let assignments = try NativeCircuitExecution.capacitySum(
                UInt64(17 * MemoryLayout<DiodeScalarAssignment>.stride), nameBytes)
            let inputs = try NativeCircuitExecution.capacitySum(
                NativeCircuitExecution.capacityProduct(count, item), assignments)
            guard let limits = record.limits.diodePreparationLimits else {
                throw SPICENativePreparationError.diodePreparation(.invalidConditions)
            }
            let binding = try NativeCircuitExecution.capacitySum(
                NativeCircuitExecution.capacitySum(limits.maximumRetainedBytes, limits.maximumTemporaryBytes),
                UInt64(2 * MemoryLayout<Instance>.stride))
            temporary = try NativeCircuitExecution.capacitySum(temporary,
                NativeCircuitExecution.capacitySum(binding, NativeCircuitExecution.capacityProduct(inputs, 2)))
        }
        return (retained,temporary)
    }
    static func binding(_ original: any CircuitDeviceBinding, record: NativeCircuitPreparationRecord,
                        capabilities: DiodeAnalysisCapabilities) throws -> any CircuitDeviceBinding {
        guard !record.diodePreparationReceipts.isEmpty, let standard=original as? StandardCircuitDeviceBinding else { return original }
        guard let limits=record.limits.diodePreparationLimits else { throw SPICENativePreparationError.diodePreparation(.invalidConditions) }
        return StandardCircuitDeviceBinding(registry: standard.registry, operatingConditions: record.operatingConditions,
            diodePreparationLimits: limits, diodeAnalyses: capabilities,
            diodeControl: NativeDiodePreparationControl(resources: record.resources))
    }
    static func reserve(record: NativeCircuitPreparationRecord, storage: NativeExecutionStorage) throws -> (any Sendable)? {
        let bytes = try capacities(record).temporary
        guard bytes > 0 else { return nil }
        return try storage.reserveTemporaryBytes(bytes)
    }
}
