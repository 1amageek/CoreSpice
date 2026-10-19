/// Complete fixed-bias observations; extracted arrays are a caller-owned value boundary.
public struct NetworkParameterResult: Sendable, AnalysisResultStorageRetaining {
    public let ports: [NetworkPort]
    public let points: [NetworkParameterPoint]
    public let operatingPoint: DCResult
    package let retainedStorage: (any Sendable)?

    init(ports: [NetworkPort], points: [NetworkParameterPoint], operatingPoint: DCResult,
         retainedStorage: (any Sendable)? = nil) {
        self.ports = ports
        self.points = points
        self.operatingPoint = operatingPoint
        self.retainedStorage = retainedStorage
    }

    package func retainingStorage(_ owner: any Sendable) -> Self {
        Self(ports: ports, points: points, operatingPoint: operatingPoint.retainingStorage(owner),
             retainedStorage: owner)
    }
}
