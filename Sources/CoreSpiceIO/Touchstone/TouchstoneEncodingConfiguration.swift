/// Explicit wire representation. Defaults preserve finite binary64 RI values.
public struct TouchstoneEncodingConfiguration: Sendable {
    public enum Version: String, Sendable { case twoPointZero = "2.0", twoPointOne = "2.1" }
    public enum FrequencyUnit: String, Sendable, CaseIterable {
        case hertz = "Hz", kilohertz = "kHz", megahertz = "MHz", gigahertz = "GHz"
        var multiplier: Double {
            switch self { case .hertz: 1; case .kilohertz: 1e3; case .megahertz: 1e6; case .gigahertz: 1e9 }
        }
    }
    public enum DataFormat: String, Sendable, CaseIterable {
        case realImaginary = "RI", magnitudeAngle = "MA", decibelAngle = "DB"
    }
    public enum MatrixFormat: String, Sendable, CaseIterable { case full = "Full", lower = "Lower", upper = "Upper" }
    public enum TwoPortOrder: String, Sendable, CaseIterable { case order21_12 = "21_12", order12_21 = "12_21" }

    public var version: Version
    public var frequencyUnit: FrequencyUnit
    public var dataFormat: DataFormat
    public var matrixFormat: MatrixFormat
    public var twoPortOrder: TwoPortOrder

    public init(
        version: Version = .twoPointOne,
        frequencyUnit: FrequencyUnit = .hertz,
        dataFormat: DataFormat = .realImaginary,
        matrixFormat: MatrixFormat = .full,
        twoPortOrder: TwoPortOrder = .order12_21
    ) {
        self.version = version
        self.frequencyUnit = frequencyUnit
        self.dataFormat = dataFormat
        self.matrixFormat = matrixFormat
        self.twoPortOrder = twoPortOrder
    }
}
