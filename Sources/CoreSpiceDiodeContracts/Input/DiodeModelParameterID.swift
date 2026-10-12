public enum DiodeModelParameterID: Int, Sendable, Hashable {
    case saturationCurrent, ideality, seriesResistance, breakdownVoltage, breakdownCurrent
    case junctionCapacitance, junctionPotential, gradingCoefficient, transitTime
    case energyGap, saturationTemperatureExponent, nominalTemperature
}
