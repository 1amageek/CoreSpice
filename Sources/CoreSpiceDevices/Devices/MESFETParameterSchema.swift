import CoreSpiceIR

enum MESFETParameterSchema {
    static let descriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "vto", defaultValue: .real(-2), description: "Threshold voltage (V)"),
        ParameterDescriptor(name: "alpha", defaultValue: .real(2), description: "Saturation transition coefficient (1/V)"),
        ParameterDescriptor(name: "beta", defaultValue: .real(2.5e-3), description: "Transconductance coefficient (A/V^2)"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(0), description: "Channel-length modulation coefficient (1/V)"),
        ParameterDescriptor(name: "b", defaultValue: .real(0.3), description: "Doping-tail parameter (1/V)"),
        ParameterDescriptor(name: "is", defaultValue: .real(1e-14), description: "Gate saturation current (A)"),
        ParameterDescriptor(name: "cgs", defaultValue: .real(0), description: "Zero-bias gate-source capacitance (F)"),
        ParameterDescriptor(name: "cgd", defaultValue: .real(0), description: "Zero-bias gate-drain capacitance (F)"),
        ParameterDescriptor(name: "pb", defaultValue: .real(1), description: "Gate junction potential (V)"),
        ParameterDescriptor(name: "fc", defaultValue: .real(0.5), description: "Forward-bias depletion coefficient"),
        ParameterDescriptor(name: "kf", defaultValue: .real(0), description: "Flicker noise coefficient"),
        ParameterDescriptor(name: "af", defaultValue: .real(1), description: "Flicker noise exponent"),
        ParameterDescriptor(name: "area", defaultValue: .real(1), description: "Area multiplier"),
        ParameterDescriptor(name: "m", defaultValue: .real(1), description: "Parallel multiplier"),
        ParameterDescriptor(name: "tnom", defaultValue: .real(27), description: "Nominal temperature (°C)"),
        ParameterDescriptor(name: "tnom_k", defaultValue: .real(300.15), description: "Nominal temperature (K)"),
    ]
}
