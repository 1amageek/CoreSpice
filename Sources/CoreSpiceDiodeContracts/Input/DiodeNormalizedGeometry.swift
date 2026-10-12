public struct DiodeNormalizedGeometry: Sendable, Hashable {
    public let areaFactor: DiodeAreaFactor
    public let perimeter: DiodePerimeterMetres
    public let areaOrigin: DiodeValueOrigin
    public let perimeterOrigin: DiodeValueOrigin
    init(areaFactor: DiodeAreaFactor, perimeter: DiodePerimeterMetres,
         areaOrigin: DiodeValueOrigin, perimeterOrigin: DiodeValueOrigin) {
        self.areaFactor = areaFactor; self.perimeter = perimeter
        self.areaOrigin = areaOrigin; self.perimeterOrigin = perimeterOrigin
    }
}
