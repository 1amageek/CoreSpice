import CoreSpiceCompactModels
import CoreSpiceIR
import CoreSpiceMOSContracts

/// Executes the supported exact native model preparation once, without source interpretation.
public struct NativeMOSDevicePreparer: MOSDevicePreparing {
    public static let implementationIdentity = "CoreSpice.NativeMOS.L1-L3.BSIM3-3.3.0.BSIM4-4.8.3.v1"
    public init() {}

    public func prepare(_ input: borrowing MOSPreparationInput, limits: MOSPreparationLimits,
                        control: any MOSPreparationControlling)
        throws(MOSPreparationFailure) -> NativePreparedMOSDevice {
        do { return try checkedPrepare(input, limits: limits, control: control) }
        catch let failure as MOSPreparationFailure { throw failure }
        catch { throw .kernelRejected(String(describing: error)) }
    }

    private func checkedPrepare(_ input: borrowing MOSPreparationInput, limits: MOSPreparationLimits,
                                control: any MOSPreparationControlling) throws -> NativePreparedMOSDevice {
        let resolved = input.resolved, conditions = input.conditions
        var budget = MOSPreparationBudget(limits: limits, control: control)
        try budget.charge()
        let identity = try MOSPreparationIdentity(resolved: resolved, conditions: conditions,
            implementationIdentity: Self.implementationIdentity)
        try budget.retain(UInt64(MemoryLayout<NativePreparedMOSDevice>.stride))
        switch resolved.release {
        case .level1, .level2, .level3:
            let parameters = try Self.classicParameters(resolved, conditions: conditions, budget: &budget)
            let receipt = try MOSPreparationReceipt(identity: identity, topology: Self.classicTopology(),
                retainedBytes: budget.retained, peakTemporaryBytes: budget.temporary, coldSetupCount: 1, limits: limits)
            try control.checkCancellation()
            return .classic(receipt: receipt, device: ClassicPreparedMOSDevice(identity: identity, parameters: parameters), control: control)
        case .bsim3_3_3_0, .bsim4_4_8_3:
            var model = try Self.project(resolved.modelCoefficients, resolved: resolved, budget: &budget)
            let modelProjection = try MOSPreparationBudget.bytes(model.capacity, of: (String, Double).self)
            var parameters = try Self.project(resolved.instanceParameters, resolved: resolved,
                existingBytes: modelProjection, budget: &budget)
            if model["tnom"] == nil { model["tnom"] = conditions.nominalKelvin - 273.15 }
            let multiplier = parameters.removeValue(forKey: "m") ?? 1
            guard multiplier.isFinite, multiplier > 0 else { throw MOSPreparationFailure.invalidParameter("m") }
            var initial = SIMD3<Double>(repeating: 0)
            var hasInitial = false
            for index in 0..<3 {
                let key = index == 0 ? "ic_vds" : index == 1 ? "ic_vgs" : "ic_vbs"
                if let value = parameters.removeValue(forKey: key) { initial[index] = value; hasInitial = true }
            }
            let projectionBytes = try MOSPreparationBudget.add(
                MOSPreparationBudget.bytes(model.capacity, of: (String, Double).self),
                MOSPreparationBudget.bytes(parameters.capacity, of: (String, Double).self))
            try budget.admitTemporary(projectionBytes)
            if resolved.release == .bsim3_3_3_0 {
                try budget.retain(BSIM3Evaluator.ownerAllocationBytes + BSIM3Evaluator.storedPayloadBytes)
                let configuration = BSIM3Configuration(polarity: resolved.polarity == .nmos ? .nmos : .pmos,
                    version: "3.3.0", temperature: conditions.ambientKelvin, modelParameters: model,
                    instanceParameters: parameters, initialConditions: hasInitial ? initial : nil)
                let device = try BSIM3PreparedDevice(configuration: configuration, multiplier: multiplier,
                    initialConditions: hasInitial ? initial : nil, preparationIdentity: identity,
                    preparationLimits: Self.kernelLimits(limits, remainingRetained: limits.maximumRetainedBytes - budget.retained + BSIM3Evaluator.ownerAllocationBytes + BSIM3Evaluator.storedPayloadBytes,
                        projectionBytes: projectionBytes, work: budget.work), preparationControl: control)
                try budget.includeChargedWork(device.preparationWorkUnits)
                try budget.retain(device.diagnosticStorageBytes)
                try budget.admitTemporary(MOSPreparationBudget.add(projectionBytes, device.preparationTemporaryBytes))
                let receipt = try MOSPreparationReceipt(identity: identity, topology: Self.topology(device.topology),
                    retainedBytes: budget.retained, peakTemporaryBytes: budget.temporary, coldSetupCount: 1, limits: limits)
                try control.checkCancellation()
                return .bsim3(receipt: receipt, device: consume device, control: control)
            }
            try budget.charge(UInt64(conditions.maximumStressIterations))
            try budget.retain(BSIM4Evaluator.ownerAllocationBytes + BSIM4Evaluator.storedPayloadBytes)
            let policy = try BSIM4PreparationPolicy(maximumStressIterations: conditions.maximumStressIterations)
            let configuration = BSIM4Configuration(polarity: resolved.polarity == .nmos ? .nmos : .pmos,
                version: "4.8.3", temperature: conditions.ambientKelvin,
                noiseRequested: conditions.analysisCapabilities.contains(.noise), maximumStressIterations: conditions.maximumStressIterations,
                modelParameters: model, instanceParameters: parameters, initialConditions: hasInitial ? initial : nil)
            let device = try BSIM4PreparedDevice(configuration: configuration, multiplier: multiplier,
                initialConditions: hasInitial ? initial : nil, preparationIdentity: identity, policy: policy,
                preparationLimits: Self.kernelLimits(limits, remainingRetained: limits.maximumRetainedBytes - budget.retained + BSIM4Evaluator.ownerAllocationBytes + BSIM4Evaluator.storedPayloadBytes,
                    projectionBytes: projectionBytes, work: budget.work), preparationControl: control)
            try budget.includeChargedWork(device.preparationWorkUnits)
            try budget.retain(device.diagnosticStorageBytes)
            try budget.admitTemporary(MOSPreparationBudget.add(projectionBytes, device.preparationTemporaryBytes))
            let receipt = try MOSPreparationReceipt(identity: identity, topology: Self.topology(device.topology),
                retainedBytes: budget.retained, peakTemporaryBytes: budget.temporary, coldSetupCount: 1, limits: limits)
            try control.checkCancellation()
            return .bsim4(receipt: receipt, device: consume device, control: control)
        // FIXME(INCOMPLETE_IMPLEMENTATION): Exact 4.5 numerical physics is not implemented.
        // Native API/CLI preparation reaches this branch after resolution; admit
        // it only after current/charge/AC/transient/noise and owner adoption proofs.
        case .bsim4_4_5: throw MOSPreparationFailure.unsupportedRelease(resolved.release)
        }
    }

    private static func kernelLimits(_ limits: MOSPreparationLimits, remainingRetained: UInt64,
                                     projectionBytes: UInt64, work: UInt64) throws(MOSPreparationFailure) -> MOSPreparationLimits {
        guard projectionBytes < limits.maximumTemporaryBytes, work < limits.maximumWorkUnits else { throw .capacityExceeded }
        return try MOSPreparationLimits(maximumRetainedBytes: remainingRetained,
            maximumTemporaryBytes: limits.maximumTemporaryBytes - projectionBytes,
            maximumDiagnosticBytes: limits.maximumDiagnosticBytes, maximumWorkUnits: limits.maximumWorkUnits - work)
    }

    private static func project(_ values: [MOSNumericParameter], resolved: ResolvedMOSInstance,
                                existingBytes: UInt64 = 0, budget: inout MOSPreparationBudget) throws(MOSPreparationFailure) -> [String: Double] {
        try budget.admitTemporary(MOSPreparationBudget.add(existingBytes, MOSPreparationBudget.bytes(values.count + 1, of: (String, Double).self)))
        var result: [String: Double] = [:]
        result.reserveCapacity(values.count + 1)
        try budget.admitTemporary(MOSPreparationBudget.add(existingBytes, MOSPreparationBudget.bytes(result.capacity, of: (String, Double).self)))
        for parameter in values {
            try budget.charge()
            let name = resolved.symbolNames[Int(parameter.symbol.rawValue)]
            guard result.updateValue(parameter.value, forKey: name) == nil else { throw .invalidParameter(name) }
        }
        return result
    }

    static func classicTopology() throws(MOSPreparationFailure) -> MOSPreparedTopology {
        try MOSPreparedTopology(localNodeCount: 4, drainPrime: 1, sourcePrime: 3, gatePrime: 2,
            gateMid: 2, bodyPrime: 4, drainBody: 4, sourceBody: 4, chargeNode: 0)
    }

    static func topology(_ value: BSIM3Topology) throws(MOSPreparationFailure) -> MOSPreparedTopology {
        try MOSPreparedTopology(localNodeCount: value.nodeCount, drainPrime: value.drainPrime,
            sourcePrime: value.sourcePrime, gatePrime: 2, gateMid: 2, bodyPrime: 4,
            drainBody: 4, sourceBody: 4, chargeNode: value.chargeNode)
    }

    static func topology(_ value: BSIM4Topology) throws(MOSPreparationFailure) -> MOSPreparedTopology {
        try MOSPreparedTopology(localNodeCount: value.nodeCount, drainPrime: value.drainPrime,
            sourcePrime: value.sourcePrime, gatePrime: value.gatePrime, gateMid: value.gateMid,
            bodyPrime: value.bodyPrime, drainBody: value.drainBody, sourceBody: value.sourceBody, chargeNode: value.chargeNode)
    }

    private static func classicParameters(_ resolved: ResolvedMOSInstance, conditions: MOSPreparationConditions,
                                          budget: inout MOSPreparationBudget) throws -> MOSFETModelParameters {
        var result = MOSFETModelParameters(operatingTemperature: conditions.ambientKelvin)
        for scope in 0..<2 {
            let values = scope == 0 ? resolved.modelCoefficients : resolved.instanceParameters
            for parameter in values {
                try budget.charge()
                let name = resolved.symbolNames[Int(parameter.symbol.rawValue)], value = parameter.value
                switch name {
                case "w": result.w = value
                case "l": result.l = value
                case "vto": result.vto = value
                case "kp": result.kp = value
                case "gamma": result.gamma = value
                case "phi": result.phi = value
                case "lambda": result.lambda = value
                case "theta": result.theta = value
                case "eta": result.eta = value
                case "kappa": result.kappa = value
                case "vmax": result.vmax = value
                case "tox": result.tox = value
                case "cgso": result.cgso = value
                case "cgdo": result.cgdo = value
                case "cgbo": result.cgbo = value
                case "cj": result.cj = value
                case "cjsw": result.cjsw = value
                case "mj": result.mj = value
                case "mjsw": result.mjsw = value
                case "pb": result.pb = value
                case "ad": result.ad = value
                case "as": result.asrc = value
                case "pd": result.pd = value
                case "ps": result.ps = value
                case "m" where value == 1: break
                case "off" where value == 0: break
                case "m", "off", "ic_vds", "ic_vgs", "ic_vbs": throw MOSPreparationFailure.unsupportedInstanceParameter(name)
                default: throw MOSPreparationFailure.invalidParameter(name)
                }
            }
        }
        if resolved.release == .level3 { try MOSL3Channel.validate(result, device: resolved.instance) }
        else { try result.validate(device: resolved.instance) }
        return result
    }
}
