/// Owned imported network data. Reference order and matrix order are port order.
public struct TouchstoneData: Sendable, Equatable {
    public let parameterKind: TouchstoneParameterKind
    public let referenceResistances: [Double]
    public let points: [TouchstonePoint]
    public var portCount: Int { referenceResistances.count }

    public init(
        parameterKind: TouchstoneParameterKind,
        referenceResistances: [Double],
        points: [TouchstonePoint]
    ) throws {
        guard !referenceResistances.isEmpty,
              referenceResistances.allSatisfy({ $0.isFinite && $0 > 0 }), !points.isEmpty else {
            throw TouchstoneError.invalidData("Positive references and at least one frequency point are required")
        }
        var previous: Double?
        for point in points {
            guard point.matrix.portCount == referenceResistances.count,
                  previous.map({ point.frequencyHz > $0 }) ?? true else {
                throw TouchstoneError.invalidData("Matrix width or increasing frequency order is invalid")
            }
            previous = point.frequencyHz
        }
        self.parameterKind = parameterKind
        self.referenceResistances = referenceResistances
        self.points = points
    }

    init(checkedKind: TouchstoneParameterKind, references: [Double], points: [TouchstonePoint]) {
        parameterKind = checkedKind
        referenceResistances = references
        self.points = points
    }
}
