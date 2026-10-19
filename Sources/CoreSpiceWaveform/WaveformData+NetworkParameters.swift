import CoreSpiceAnalysis
import CoreSpiceCompile

extension WaveformData {
    /// Finite presentation; conditional impedance and stability remain in the typed result.
    public static func from(networkResult: NetworkParameterResult, title: String? = nil) -> WaveformData {
        let count = networkResult.ports.count
        var variables: [VariableDescriptor] = []
        for kind in ["S", "Y"] {
            for row in 0..<count {
                for column in 0..<count {
                    variables.append(.init(name: "\(kind)[\(row + 1),\(column + 1)]",
                        unit: kind == "S" ? .dimensionless : .siemens, type: .parameter, index: variables.count))
                }
            }
        }
        let rows = networkResult.points.map { point in
            (point.s.values + point.y.values).map { (real: $0.real, imag: $0.imag) }
        }
        return WaveformData(metadata: .init(title: title, analysisType: .networkParameters,
            pointCount: networkResult.points.count, variableCount: variables.count, isComplex: true,
            options: ["network_profile": "voltage-controlled.real-power-wave.v1", "matrix_axes": "response,excitation"]),
            sweepVariable: .init(name: "frequency", unit: .hertz, type: .frequency, index: 0),
            sweepValues: networkResult.points.map(\.frequency), variables: variables, complexData: rows)
            .retainingStorage(networkResult.retainedStorage)
    }
}
