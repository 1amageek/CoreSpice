import Foundation
import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts

/// Once-resolved preparation; the schema owns input roles and feature requirements.
public struct NativeDiodeDevicePreparer: DiodeDevicePreparing {
    public static let implementationIdentity = "CoreSpice.NativeDiode.Preparation.v2"
    public init() {}
    public func prepare(_ input: borrowing DiodePreparationInput, limits: DiodePreparationLimits,
                        control: any DiodePreparationControlling)
        throws(DiodePreparationFailure) -> NativePreparedDiodeDevice {
        try control.checkCancellation()
        let resolved = input.resolved
        let features = resolved.model.input.requiredFeatures.union(resolved.input.requiredFeatures)
        let supported: DiodeFeatureSet = resolved.profile == .coreDiodeV1 ? .none
            : .init([.breakdown, .depletionCharge, .diffusionCharge])
        do { try features.requireSupport(by: supported) } catch { throw .schema(error) }
        let retained = UInt64(MemoryLayout<NativePreparedDiodeDevice>.stride + DiodeTransientHistory.retainedCapacityBytes)
        let temporary = UInt64(MemoryLayout<DiodeModelParameters>.stride)
        let work: UInt64 = 48
        guard retained <= limits.maximumRetainedBytes, temporary <= limits.maximumTemporaryBytes else {
            throw .capacityExceeded
        }
        guard work <= limits.maximumWorkUnits else { throw .workLimitExceeded }
        try control.chargeWork(work)
        let temperature: TemperatureKelvin
        do { temperature = try resolved.input.effectiveTemperature(in: input.environment) }
        catch { throw .schema(error) }
        let model = resolved.model.input
        func required(_ id: DiodeModelParameterID) throws(DiodePreparationFailure) -> Double {
            guard let value = model.value(for: id) else { throw .invalidEffectiveValue(id) }
            return value
        }
        let area = resolved.input.geometry.areaFactor.value
        let replicas = resolved.input.multiplicity.value
        let scale = area * replicas
        guard scale.isFinite, scale > 0 else { throw .invalidEffectiveValue(.saturationCurrent) }
        let parameters = DiodeModelParameters(saturationCurrent: try required(.saturationCurrent),
            emissionCoefficient: try required(.ideality), seriesResistance: 0,
            breakdownVoltage: model.value(for: .breakdownVoltage) ?? 1e100,
            breakdownCurrent: try required(.breakdownCurrent) * scale,
            junctionCapacitance: try required(.junctionCapacitance) * scale,
            junctionPotential: try required(.junctionPotential), gradingCoefficient: try required(.gradingCoefficient),
            transitTime: try required(.transitTime), energyGap: try required(.energyGap),
            saturationCurrentExponent: try required(.saturationTemperatureExponent),
            nominalTemperature: model.nominalTemperature.value, operatingTemperature: temperature.value)
        let saturation = parameters.effectiveSaturationCurrent * scale
        let nvt = parameters.emissionCoefficient * parameters.thermalVoltage
        guard saturation.isFinite, saturation > 0, nvt.isFinite, nvt > 0 else {
            throw .invalidEffectiveValue(.saturationCurrent)
        }
        let originalCapacitance = try required(.junctionCapacitance)
        guard parameters.junctionCapacitance.isFinite,
              originalCapacitance == 0 || parameters.junctionCapacitance > 0 else {
            throw .invalidEffectiveValue(.junctionCapacitance)
        }
        let breakdownAmplitude: Double?
        if let bv = model.value(for: .breakdownVoltage) {
            let b = bv / nvt
            let fraction = -expm1(-b)
            guard b.isFinite, b > 0, fraction.isFinite, fraction > 0 else {
                throw .invalidEffectiveValue(.breakdownVoltage)
            }
            let ibv = parameters.breakdownCurrent
            let baselineCurrent = saturation * fraction
            guard baselineCurrent.isFinite, baselineCurrent > 0,
                  ibv.isFinite, ibv > 0, ibv >= baselineCurrent else {
                throw .invalidEffectiveValue(.breakdownCurrent)
            }
            // Equality is valid; never silently raise an incompatible IBV.
            let amplitude = (ibv - baselineCurrent) / fraction
            guard amplitude.isFinite, amplitude >= 0,
                  amplitude > 0 || ibv == baselineCurrent else {
                throw .invalidEffectiveValue(.breakdownCurrent)
            }
            breakdownAmplitude = amplitude
        } else { breakdownAmplitude = nil }
        let identity = DiodePreparationIdentity(input: input, effectiveTemperature: temperature,
            implementationIdentity: Self.implementationIdentity)
        let receipt = try DiodePreparationReceipt(identity: identity, requiredFeatures: features,
            retainedBytes: retained, peakTemporaryBytes: temporary, workUnits: work, limits: limits)
        try control.checkCancellation()
        return NativePreparedDiodeDevice(receipt: receipt, parameters: parameters,
            effectiveSaturationCurrent: saturation, breakdownAmplitude: breakdownAmplitude, control: control)
    }
}
