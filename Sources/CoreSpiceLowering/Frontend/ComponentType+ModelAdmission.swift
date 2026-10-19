import CoreSpiceParsedIR

extension ComponentType {
    var requiresModelForNativeExecution: Bool {
        switch self {
        case .diode, .bjt, .jfet, .mosfet, .mesfet, .uniformRC, .switch_, .currentSwitch, .osdi:
            return true
        default:
            return false
        }
    }

    func accepts(model: ParsedModel) -> Bool {
        switch self {
        case .osdi:
            return model.type == .osdi
        case .resistor:
            return model.type == .resistor
        case .capacitor:
            return model.type == .capacitor
        case .diode:
            return model.type == .diode
        case .bjt:
            return model.type == .npn || model.type == .pnp
        case .mosfet:
            return model.type == .nmos || model.type == .pmos
        case .jfet:
            return model.type == .njf || model.type == .pjf
        case .mesfet:
            return model.type == .nmf || model.type == .pmf
        case .switch_:
            return model.type == .sw
        case .currentSwitch:
            return model.type == .csw
        case .transmissionLine:
            return model.type == .ltra
        case .uniformRC:
            return model.type == .urc
        default:
            return true
        }
    }
}
