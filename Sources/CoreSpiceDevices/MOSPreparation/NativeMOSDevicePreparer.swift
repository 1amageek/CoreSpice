import CoreSpiceIR
import CoreSpiceMOSContracts

/// Prepares the admitted classic L1/L2/L3 value once, without source interpretation.
public struct NativeMOSDevicePreparer: MOSDevicePreparing {
    public static let implementationIdentity = "CoreSpice.NativeMOS.L1-L3.v2"
    public init() {}

    public func prepare(_ input: borrowing MOSPreparationInput, limits: MOSPreparationLimits,
                        control: any MOSPreparationControlling)
        throws(MOSPreparationFailure) -> NativePreparedMOSDevice {
        do {
            let resolved = input.resolved, conditions = input.conditions
            var budget = MOSPreparationBudget(limits: limits, control: control)
            try budget.charge()
            let identity = try MOSPreparationIdentity(resolved: resolved, conditions: conditions,
                implementationIdentity: Self.implementationIdentity)
            try budget.retain(UInt64(MemoryLayout<NativePreparedMOSDevice>.stride))
            let parameters = try Self.classicParameters(resolved, conditions: conditions, budget: &budget)
            let receipt = try MOSPreparationReceipt(identity: identity, topology: MOSPreparedTopology(),
                retainedBytes: budget.retained, peakTemporaryBytes: budget.temporary, coldSetupCount: 1, limits: limits)
            try control.checkCancellation()
            return .classic(receipt: receipt, device: ClassicPreparedMOSDevice(identity: identity, parameters: parameters), control: control)
        } catch let failure as MOSPreparationFailure { throw failure }
        catch { throw .kernelRejected(String(describing: error)) }
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
