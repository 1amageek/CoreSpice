import CoreSpiceCompactModels
import CoreSpiceIR
import CoreSpiceMOSContracts

/// One prepared native owner; public receipts never carry executable authority.
public enum NativePreparedMOSDevice: ~Copyable, PreparedMOSDevice {
    case classic(receipt: MOSPreparationReceipt, device: ClassicPreparedMOSDevice, control: any MOSPreparationControlling)
    case bsim3(receipt: MOSPreparationReceipt, device: BSIM3PreparedDevice, control: any MOSPreparationControlling)
    case bsim4(receipt: MOSPreparationReceipt, device: BSIM4PreparedDevice, control: any MOSPreparationControlling)

    case bsim45(receipt: MOSPreparationReceipt, device: BSIM45PreparedDevice, control: any MOSPreparationControlling)

    public var receipt: MOSPreparationReceipt {
        switch self {
        case .classic(let receipt, _, _): return receipt
        case .bsim3(let receipt, _, _): return receipt
        case .bsim4(let receipt, _, _): return receipt
        case .bsim45(let receipt, _, _): return receipt
        }
    }

    public consuming func bind(instance: Instance, context: inout BindingContext)
        throws(MOSBindingFailure) -> any BoundDevice {
        do {
            switch consume self {
            case .classic(let receipt, let device, let control):
                try Self.validate(receipt, identity: device.identity, instance: instance, context: context, control: control)
                guard receipt.topology == (try NativeMOSDevicePreparer.classicTopology()) else { throw MOSBindingFailure.topologyMismatch }
                return try device.bind(instance: instance, context: &context, control: control)
            case .bsim3(let receipt, let device, let control):
                try Self.validate(receipt, identity: device.preparationIdentity, instance: instance, context: context, control: control)
                guard receipt.topology == (try NativeMOSDevicePreparer.topology(device.topology)) else { throw MOSBindingFailure.topologyMismatch }
                return try device.bind(instance: instance, context: &context, control: control)
            case .bsim4(let receipt, let device, let control):
                try Self.validate(receipt, identity: device.preparationIdentity, instance: instance, context: context, control: control)
                guard receipt.topology == (try NativeMOSDevicePreparer.topology(device.topology)) else { throw MOSBindingFailure.topologyMismatch }
                return try device.bind(instance: instance, context: &context, control: control)
            case .bsim45(let receipt, let device, let control):
                try Self.validate(receipt, identity: device.preparationIdentity, instance: instance, context: context, control: control)
                guard receipt.topology == (try NativeMOSDevicePreparer.topology(device.topology)) else { throw MOSBindingFailure.topologyMismatch }
                return try device.bind(instance: instance, context: &context, control: control)
            }
        } catch let failure as MOSBindingFailure { throw failure }
        catch let failure as MOSPreparationFailure {
            if failure == .cancelled { throw .cancelled }
            throw .topologyMismatch
        } catch let failure as BSIM3Error {
            if case .invalidConfiguration = failure { throw .terminalInitialConditionsConflict }
            throw .invalidMatrixMapping
        } catch let failure as BSIM4Error {
            if case .invalidConfiguration = failure { throw .terminalInitialConditionsConflict }
            throw .invalidMatrixMapping
        } catch let failure as BSIM45DeviceError {
            if case .terminalInitialConditionsConflict = failure { throw .terminalInitialConditionsConflict }
            throw .invalidMatrixMapping
        } catch { throw .invalidMatrixMapping }
    }

    private static func validate(_ receipt: MOSPreparationReceipt, identity: MOSPreparationIdentity?,
                                 instance: Instance, context: BindingContext, control: any MOSPreparationControlling)
        throws(MOSBindingFailure) {
        do { try control.checkCancellation() } catch { throw .cancelled }
        guard let identity, identity == receipt.identity else { throw .identityMismatch }
        guard case .prepared(let recorded) = instance.mos else { throw .missingPreparedReceipt }
        guard recorded == receipt, instance.name == identity.resolved.instance else { throw .identityMismatch }
        let prefix = identity.resolved.polarity == .nmos ? "nmos" : "pmos"
        let qualifiedType = "\(prefix)_l\(identity.resolved.release.level)"
        let isLevel1Alias = identity.resolved.release == .level1 && instance.typeName == prefix
        guard instance.typeName == qualifiedType || isLevel1Alias else { throw .identityMismatch }
        guard context.operatingConditions.temperatureKelvin == identity.conditions.ambientKelvin,
              context.operatingConditions.nominalTemperatureKelvin == identity.conditions.nominalKelvin else {
            throw .conditionsMismatch
        }
        guard instance.nodes.count == 4, instance.ownedNodes.count == receipt.topology.auxiliaryNodeCount else {
            throw .topologyMismatch
        }
    }
}
